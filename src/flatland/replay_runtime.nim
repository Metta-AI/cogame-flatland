## Replaying a `COWLDFLT` file: rebuild the world from the recorded config,
## re-step the SAME sim module from the recorded orders, and compare
## `sim.gameHash()` against the recorded hash EVERY tick. One divergent bit is
## caught at the tick it happens.
##
## Forked from `coworld-ctf`'s `src/ctf/replay_runtime.nim`. The load-time
## PRE-SCAN is this fork's addition: it re-simulates the whole episode once
## headlessly and records the per-tick cumulative arrivals and on-time count,
## the jam / deadlock / malfunction spans, the lull spans and the beat ticks,
## which is what lets the on-time sparkline and the scrubber beats draw at
## full width on the FIRST frame instead of growing in.

import std/[json, tables]

import sim, replays, sim_config

type
  Beat* = object
    tick*: int
    kind*: string        ## arrival | malfunction | deadlock | fallback | end
    slot*: int
    label*: string

  Prescan* = object
    ticks*: int
    arrivals*: seq[int]        ## cumulative, per tick
    onTime*: seq[int]          ## cumulative, per tick
    jamSpans*: seq[array[2, int]]
    deadlockSpans*: seq[array[2, int]]
    lullSpans*: seq[array[2, int]]
    beats*: seq[Beat]
    endRule*: EndRule
    reason*: EndReason

  ReplayPlayer* = object
    data*: ReplayData
    ordersByTurn*: Table[int, seq[ReplayRecord]]
    stopTick*: int
    stopRule*: EndRule
    hashes*: Table[int, uint64]
    hashMismatchTick*: int
    prescan*: Prescan
    finished*: bool

  ReplayRuntime* = object
    sim*: SimServer
    player*: ReplayPlayer

const LullTicks* = 40

proc configFromReplay*(replay: ReplayData): GameConfig =
  result = defaultGameConfig()
  let node = replay.configNode()
  # `network` is the RESOLVED map name; the sim re-derives it from
  # `networkPool` + `seed`, so the POOL is what has to be restored. A replay
  # that carries neither is pre-`networkPool` and was mainline by default.
  var patch = newJObject()
  for key in ["networkPool", "num_agents", "trainsPerSeat", "maxTicks",
              "turnTicks", "parOnTime", "slackTicks", "minJourneyCells",
              "departStagger", "malfunctionRate", "jamTicks", "deadlockTicks",
              "quiesceTicks", "fastMode", "showPlayerLabels", "players",
              "slots"]:
    if node.hasKey(key):
      patch[key] = node[key]
  if node.hasKey("minDuration"):
    patch["malfunctionMinDuration"] = node["minDuration"]
  if node.hasKey("maxDuration"):
    patch["malfunctionMaxDuration"] = node["maxDuration"]
  if node.hasKey("seed"):
    patch["seed"] = node["seed"]
  result.update(patch)

proc applyOrdersRecord(game: SimServer, record: ReplayRecord) =
  for order in record.orders:
    game.applyOrder(order.train, TrainOrder(verb: order.verb, arg: order.arg))

proc turnOf(player: ReplayPlayer, tick, turnTicks: int): int =
  if turnTicks <= 0: 1 else: (tick div turnTicks) + 1

proc newPlayer(data: ReplayData): ReplayPlayer =
  result.data = data
  result.stopTick = -1
  result.stopRule = erTickCap
  result.hashMismatchTick = -1
  for record in data.records:
    case record.kind
    of rrOrders:
      result.ordersByTurn.mgetOrPut(record.turn, @[]).add(record)
    of rrHash:
      result.hashes[record.tick] = record.hash
    of rrStop:
      result.stopTick = record.tick
      result.stopRule = record.endRule
    else:
      discard

proc applyStop(game: SimServer, rule: EndRule) =
  ## The SAME proc applies the recorded stop on record and on playback.
  case rule
  of erWallClock: game.stopAtWallClock()
  of erFault: game.faultStop("recorded fault")
  else: discard

proc prescanEpisode*(data: ReplayData): Prescan =
  ## Re-simulate the whole episode once, headlessly. 496 ticks x 24 trains of
  ## integer work — single-digit milliseconds in wasm.
  var player = newPlayer(data)
  let game = newSimServer(configFromReplay(data))
  game.startPlaying()
  var
    jamFrom = -1
    deadlockFrom = -1
    quietFrom = 1
  result.arrivals.add(0)
  result.onTime.add(0)
  while game.phase == Playing:
    let turn = player.turnOf(game.tick, game.config.turnTicks)
    if game.tick mod game.config.turnTicks == 0 and player.ordersByTurn.hasKey(turn):
      for record in player.ordersByTurn[turn]:
        game.applyOrdersRecord(record)
    if player.stopTick >= 0 and game.tick >= player.stopTick:
      game.applyStop(player.stopRule)
      break
    game.step()
    result.arrivals.add(game.arrivedTotal)
    result.onTime.add(game.fleetOnTime)
    var interesting = false
    for event in game.frameEvents:
      case event.kind
      of Arrive:
        interesting = true
        result.beats.add(Beat(tick: game.tick, kind: "arrival", slot: event.slot,
          label: trainId(event.train) & " arrives " &
            $StationLetters[event.station] &
            (if event.cell == 1: " on time" else: " late")))
      of Malfunction:
        interesting = true
        result.beats.add(Beat(tick: game.tick, kind: "malfunction",
          slot: event.slot,
          label: trainId(event.train) & " breaks down for " & $event.amount & " ticks"))
      of Deadlock:
        interesting = true
        result.beats.add(Beat(tick: game.tick, kind: "deadlock", slot: -1,
          label: "deadlock"))
      of Depart, Jam:
        interesting = true
      else:
        discard
    if interesting:
      if game.tick - quietFrom >= LullTicks:
        result.lullSpans.add([quietFrom, game.tick - 1])
      quietFrom = game.tick + 1
    if game.activeJam.len > 0 and jamFrom < 0:
      jamFrom = game.tick
    elif game.activeJam.len == 0 and jamFrom >= 0:
      result.jamSpans.add([jamFrom, game.tick])
      jamFrom = -1
    if game.activeDeadlock.len > 0 and deadlockFrom < 0:
      deadlockFrom = game.tick
    elif game.activeDeadlock.len == 0 and deadlockFrom >= 0:
      result.deadlockSpans.add([deadlockFrom, game.tick])
      deadlockFrom = -1
  if jamFrom >= 0:
    result.jamSpans.add([jamFrom, game.tick])
  if deadlockFrom >= 0:
    result.deadlockSpans.add([deadlockFrom, game.tick])
  if game.tick - quietFrom >= LullTicks:
    result.lullSpans.add([quietFrom, game.tick])
  result.ticks = game.tick
  result.endRule = game.endRule
  result.reason = game.reason
  result.beats.add(Beat(tick: game.tick, kind: "end", slot: -1,
    label: $game.fleetOnTime & " of " & $game.trains.len & " on time"))
  for node in data.chatRecords():
    if node{"k"}.getStr() == "fallback":
      let turn = node{"turn"}.getInt()
      result.beats.add(Beat(
        tick: max(0, (turn - 1) * DefaultTurnTicks),
        kind: "fallback", slot: node{"slot"}.getInt(),
        label: seatAlias(node{"slot"}.getInt()) & " missed the call (" &
          node{"cause"}.getStr() & ")"))

proc initReplayRuntime*(data: ReplayData): ReplayRuntime =
  ## Rebuilds the world and runs the pre-scan. Raises on a malformed replay.
  result.player = newPlayer(data)
  result.player.prescan = prescanEpisode(data)
  result.sim = newSimServer(configFromReplay(data))
  for record in data.records:
    if record.kind == rrJoin and record.slot < result.sim.seats.len:
      result.sim.seats[record.slot].name = record.name
      result.sim.seats[record.slot].joined = true
  for node in data.chatRecords():
    if node{"k"}.getStr() != "register":
      continue
    let slot = node{"slot"}.getInt()
    if slot >= 0 and slot < result.sim.seats.len:
      result.sim.seats[slot].kind = node{"kind"}.getStr()
      result.sim.seats[slot].baseline = node{"baseline"}.getStr()
      result.sim.seats[slot].policyLabel = node{"policy"}.getStr()
  result.sim.startPlaying()

proc checkReplayHash*(runtime: var ReplayRuntime) =
  let recorded = runtime.player.hashes.getOrDefault(runtime.sim.tick, 0'u64)
  if recorded != 0'u64 and recorded != runtime.sim.gameHash() and
      runtime.player.hashMismatchTick < 0:
    runtime.player.hashMismatchTick = runtime.sim.tick

proc advanceReplayFrame*(runtime: var ReplayRuntime) =
  ## One playback tick: apply this turn's recorded orders, step, verify.
  if runtime.sim.phase != Playing:
    runtime.player.finished = true
    return
  let turn = runtime.player.turnOf(runtime.sim.tick, runtime.sim.config.turnTicks)
  if runtime.sim.tick mod runtime.sim.config.turnTicks == 0 and
      runtime.player.ordersByTurn.hasKey(turn):
    for record in runtime.player.ordersByTurn[turn]:
      runtime.sim.applyOrdersRecord(record)
  if runtime.player.stopTick >= 0 and runtime.sim.tick >= runtime.player.stopTick:
    runtime.sim.applyStop(runtime.player.stopRule)
    runtime.player.finished = true
    return
  runtime.sim.step()
  runtime.checkReplayHash()

proc seekTo*(runtime: var ReplayRuntime, tick: int) =
  ## Seeking re-simulates from tick 0 — the episode is a second of integer
  ## work, and re-deriving is the only way a seek can land on a state that is
  ## bit-identical to the one playback would have reached.
  let mismatch = runtime.player.hashMismatchTick
  let prescan = runtime.player.prescan
  let data = runtime.player.data
  runtime = initReplayRuntime(data)
  runtime.player.hashMismatchTick = mismatch
  runtime.player.prescan = prescan
  while runtime.sim.tick < tick and runtime.sim.phase == Playing:
    runtime.advanceReplayFrame()

