## The wasm entry point of the static replay viewer.
##
## Forked from `coworld-ctf`'s `replay-viewer/ctf_replay.nim`, structure kept
## EXACTLY: the `stampStage` fixed progress buffer that survives an allocation
## abort, `bytesFromPointer`, the try/except publishing `lastError`, and the
## `emscripten_exit_with_live_runtime()` epilogue that stops Nim's generated
## `main` from running module destructors while JS keeps calling in.
##
## Two additions, both from the design note:
##   * a LOAD-TIME PRE-SCAN (`replay_runtime.prescanEpisode`) so the on-time
##     sparkline and the scrubber beats draw at FULL WIDTH on the first frame;
##   * `flatland_mismatch_tick`, which returns `checkReplayHash`'s divergence
##     tick or -1.
##
## It imports the SAME `src/flatland/sim.nim` the server does, which is the
## whole point: the browser re-steps the episode from the recorded orders and
## compares `gameHash` against the recorded hash every tick.

import
  std/[json, strutils],
  flatland/[broadcast, global, replay_runtime, replays, sim]

var
  runtimeLoaded = false
  runtime: ReplayRuntime
  viewer: GlobalViewerState
  packet: seq[uint8]
  lastError: string
  playing = true
  looping = false
  skipLulls = false
  speedIndex = 0
  halfPhase = false
    ## Frame parity while at 1/2x speed (ReplayHalfSpeedIndex): ticks advance
    ## only on the odd frames, toggled once per flatlandFrame call.
  frameAccumulator = 0
  timelineSent = false

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals instead of trapping. The bundle is therefore linked
## with -s ABORTING_MALLOC=1 — allocation failure aborts the runtime loudly —
## and this fixed buffer, stamped BEFORE each risky phase, stays readable from
## JS after the abort (aborting kills the call stack, not the linear memory),
## so the page can still report what the runtime was doing.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string
  frameStage: string

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc placements(): seq[TrainPlacement] =
  result = newSeq[TrainPlacement](runtime.sim.trains.len)
  for i, train in runtime.sim.trains:
    result[i] = TrainPlacement(
      active: train.onGrid(), cell: train.cell, seat: train.owner,
      speed: train.ticksPerCell, facing: int(train.heading),
      held: train.state == tsHeld,
      broken: train.state == tsMalfunctioning,
      deadlocked: i in runtime.sim.activeDeadlock,
      late: runtime.sim.tick > train.scheduledArrival)

proc renderCurrent(events: JsonNode) =
  let chrome = buildStateJson(runtime.sim, events,
    playing = playing, speed = replayDisplaySpeed(speedIndex),
    maxTick = max(1, runtime.player.prescan.ticks), startTick = 0,
    looping = looping, transportEnabled = true, skipLulls = skipLulls,
    fastForwarding = false, mismatchTick = runtime.player.hashMismatchTick,
    prescan = runtime.player.prescan, includeTimeline = not timelineSent)
  timelineSent = true
  packet = buildViewerPacket(runtime.sim.map, placements(), viewer, chrome)

proc flatlandLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "flatland_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    let replayData = parseReplayBytes(data.bytesFromPointer(int(length)))
    stampStage("pre-scan the episode")
    runtime = initReplayRuntime(replayData)
    viewer = initGlobalViewerState()
    timelineSent = false
    runtimeLoaded = true
    frameStage = "advance replay (" & runtime.sim.network & ")"
    stampStage("render first frame (" & runtime.sim.network & ")")
    renderCurrent(newJArray())
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg & "\n" & error.getStackTrace()
    return 0

proc applyCommand(text: string) =
  ## The transport vocabulary the inherited chrome sends. Seeks re-derive from
  ## tick 0, which is the only way a seek can land on a state that is
  ## bit-identical to the one playback would have reached.
  if text.len == 0:
    return
  if text.startsWith("s:"):
    try:
      runtime.seekTo(max(0, parseInt(text[2 .. ^1])))
    except CatchableError:
      discard
    return
  if text.startsWith("v:"):
    return                                   ## no per-train point of view here
  case text
  of " ": playing = not playing
  of ",": runtime.seekTo(0)
  of "b": runtime.seekTo(max(0, runtime.sim.tick - 5 * TargetFps))
  of ".": runtime.seekTo(runtime.sim.tick + 5 * TargetFps)
  of "e": runtime.seekTo(max(1, runtime.player.prescan.ticks))
  of "r": looping = not looping
  of "f": skipLulls = not skipLulls
  of "+", "=", "-", "_", "1", "2", "3", "4", "5", "8", "6":
    applySpeedCommand(speedIndex, text)
  else: discard

proc flatlandInput(data: ptr uint8, length: cint)
    {.exportc: "flatland_input", cdecl.} =
  if not runtimeLoaded:
    return
  viewer.applyGlobalViewerMessage(data.bytesFromPointer(int(length)))
  if viewer.replaySeekTick >= 0:
    applyCommand("s:" & $viewer.replaySeekTick)
    viewer.replaySeekTick = -1
  for command in viewer.replayCommands:
    applyCommand(command)
  viewer.replayCommands.setLen(0)

proc inLull(tick: int): bool =
  for span in runtime.player.prescan.lullSpans:
    if tick >= span[0] and tick <= span[1]:
      return true
  false

proc flatlandFrame(): cint {.exportc: "flatland_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  halfPhase = not halfPhase
  stampStage(frameStage)
  try:
    var events = newJArray()
    if playing:
      ## Playback rate is 1 tick per animation frame at the base speed; the
      ## speed chips multiply it, and 1/2x spends a tick only every other
      ## frame. Skip-lulls fast-forwards quiet stretches at the integer speed.
      var steps = replayStepBudget(speedIndex, halfPhase)
      if skipLulls and inLull(runtime.sim.tick):
        steps = replaySpeed(speedIndex) * 8
      for _ in 0 ..< steps:
        if runtime.sim.phase != Playing:
          if looping:
            runtime.seekTo(0)
            playing = true
          else:
            playing = false
          break
        runtime.advanceReplayFrame()
        for event in stepEvents(runtime.sim):
          events.add(event)
    renderCurrent(events)
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg & "\n" & error.getStackTrace()
    return -1

proc flatlandPacketPointer(): ptr uint8 {.exportc: "flatland_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: packet[0].addr

proc flatlandPacketLength(): cint {.exportc: "flatland_packet_len", cdecl.} =
  cint(packet.len)

proc flatlandMismatchTick(): cint {.exportc: "flatland_mismatch_tick", cdecl.} =
  if runtimeLoaded: cint(runtime.player.hashMismatchTick) else: -1

proc flatlandErrorPointer(): ptr uint8 {.exportc: "flatland_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc flatlandErrorLength(): cint {.exportc: "flatland_error_len", cdecl.} =
  cint(lastError.len)

proc flatlandStagePointer(): ptr uint8 {.exportc: "flatland_stage_ptr", cdecl.} =
  ## Unlike flatland_error_*, this stays valid after an allocation-failure
  ## abort, so JS can report what the runtime was doing.
  if stageNoteLen == 0: nil else: cast[ptr uint8](stageNote[0].addr)

proc flatlandStageLength(): cint {.exportc: "flatland_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing the baked bed, the chips, the fonts — everything — while the wasm
  # module stays alive and JS keeps calling flatland_load_replay/flatland_frame.
  # Unwinding main through emscripten's live-runtime exit skips the destructor
  # epilogue entirely, so globals stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
