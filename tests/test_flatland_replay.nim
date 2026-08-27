## The replay: record then re-derive for EVERY end reason, self-sufficiency,
## and the strict-UTF-8 forensics summary. Design note §Tests 29-32.

import std/[json, os, osproc, strutils, unicode]

import flatland/[sim, baselines, directives, replays, replay_runtime, roster,
                 decide]
import ./helpers

echo "test_flatland_replay"

proc record(seed: uint64, kinds: array[4, Baseline], maxTicks: int,
            forceStop: EndRule = erTickCap, stopAt = -1,
            pool = "mainline", trainsPerSeat = 6):
    tuple[bytes: string, game: SimServer] =
  ## Records one episode, optionally forcing a wall-clock or fault stop at a
  ## given tick — written as the LOAD-BEARING stop record, and applied by the
  ## SAME proc on record and on playback.
  var config = defaultGameConfig()
  config.seed = seed
  config.maxTicks = maxTicks
  config.networkPool = pool
  config.trainsPerSeat = trainsPerSeat
  config.parOnTime = if pool == "mainline": 15 else: 9
  let game = newSimServer(config)
  var writer = initReplayWriter(config.resolvedConfigJson(game.network))
  for slot in 0 ..< game.seatCount():
    game.seats[slot].kind = "scripted"
    game.seats[slot].baseline = $kinds[slot]
    game.seats[slot].policyLabel = $kinds[slot]
    game.seats[slot].name = "policy-" & $slot
    writer.writeJoin(slot, game.seats[slot].name, "token-" & $slot)
    writer.writeChat(registerRecord(slot, seatAlias(slot), $kinds[slot],
                                    "scripted", $kinds[slot]))
  game.startPlaying()
  while game.phase == Playing:
    if game.tick mod config.turnTicks == 0:
      let turn = (game.tick div config.turnTicks) + 1
      let world = game.testWorld()
      for seat in 0 ..< 4:
        let directive = scriptedDirective(world, kinds[seat], game.testContext(seat))
        var orders: seq[ReplayOrder]
        for order in directive.orders:
          game.applyOrder(order.train, TrainOrder(verb: order.verb, arg: order.arg))
          orders.add(ReplayOrder(train: order.train, verb: order.verb,
                                 arg: order.arg))
        writer.writeOrders(turn, seat, orders)
        writer.writeChat(directiveRecord(game, turn, seat, directive,
                                         game.seatObservation(seat, turn, 31)))
    if stopAt >= 0 and game.tick >= stopAt:
      writer.writeStop(game.tick, forceStop)
      case forceStop
      of erWallClock: game.stopAtWallClock()
      of erFault: game.faultStop("synthetic fault")
      else: discard
      break
    game.step()
    writer.writeHash(game.tick, game.gameHash())
  writer.writeChat(resultRecord(game.networkResultsJson()))
  (writer.finish(), game)

proc rederive(bytes: string): ReplayRuntime =
  result = initReplayRuntime(parseReplayBytes(bytes))
  while result.sim.phase == Playing and not result.player.finished:
    result.advanceReplayFrame()

# 29. record then re-derive, EVERY end reason --------------------------------
check "record -> re-derive matches at every tick, for every end reason":
  let kinds = [blYielder, blTimetable, blYielder, blTimetable]
  # tickCap
  block tickCap:
    let (bytes, game) = record(101, kinds, 120)
    doAssert game.endRule in {erTickCap, erAllArrived, erQuiescent}
    let runtime = rederive(bytes)
    doAssert runtime.player.hashMismatchTick == -1
    doAssert runtime.sim.tick == game.tick
    doAssert runtime.sim.arrivedTotal == game.arrivedTotal
  # quiescent is reached through RECORDED ORDERS, so it re-derives like the
  # rest: every seat holds every train, nothing departs, and `quietTicks` runs
  # up to `quiesceTicks`. (The old block forced `earliestDeparture` on the live
  # world, which playback rebuilds from the config and therefore could never
  # reproduce; it recorded hashes and never called `rederive`.)
  block quiescent:
    var config = defaultGameConfig()
    config.seed = 3
    config.maxTicks = 96
    config.quiesceTicks = 8
    let game = newSimServer(config)
    var writer = initReplayWriter(config.resolvedConfigJson(game.network))
    for slot in 0 ..< game.seatCount():
      game.seats[slot].name = "policy-" & $slot
      writer.writeJoin(slot, game.seats[slot].name, "")
    game.startPlaying()
    while game.phase == Playing:
      if game.tick mod config.turnTicks == 0:
        let turn = (game.tick div config.turnTicks) + 1
        for seat in 0 ..< 4:
          var orders: seq[ReplayOrder]
          for i in game.seatTrains(seat):
            game.applyOrder(i, TrainOrder(verb: ovHold))
            orders.add(ReplayOrder(train: i, verb: ovHold, arg: ""))
          writer.writeOrders(turn, seat, orders)
      game.step()
      writer.writeHash(game.tick, game.gameHash())
    doAssert game.endRule == erQuiescent,
      "an all-hold episode must quiesce, got " & $game.endRule
    doAssert game.tick == config.quiesceTicks
    writer.writeChat(resultRecord(game.networkResultsJson()))
    let bytes = writer.finish()
    doAssert parseReplayBytes(bytes).resultDocument(){"endRule"}.getStr() ==
      "quiescent"
    let runtime = rederive(bytes)
    doAssert runtime.sim.endRule == erQuiescent,
      "the re-derived episode ended on " & $runtime.sim.endRule
    doAssert runtime.sim.tick == game.tick
    doAssert runtime.player.hashMismatchTick == -1,
      "hash mismatch at tick " & $runtime.player.hashMismatchTick &
      " on a quiescent episode"
  block allArrived:
    # allArrived is NOT reachable through recorded orders: it needs all
    # twenty-four trains home, and scripted play strands some of them in a
    # permanent deadlock long before that (test_flatland_sim asserts exactly
    # that). What is asserted here is the property re-derivation rests on —
    # the rule fires from sim state alone, and two independent constructions
    # of the same state agree bit for bit.
    proc arrivedWorld(): SimServer =
      var config = defaultGameConfig()
      config.seed = 3
      result = newSimServer(config)
      result.startPlaying()
      for i in 0 ..< result.trains.len:
        result.trains[i].state = tsArrived
        result.trains[i].cell = -1
      result.step()
    let a = arrivedWorld()
    let b = arrivedWorld()
    doAssert a.endRule == erAllArrived and a.reason == reComplete
    doAssert a.tick == b.tick
    doAssert a.gameHash() == b.gameHash()
    doAssert a.hashes == b.hashes
  # wallClock and fault are LOAD-BEARING records
  for rule in [erWallClock, erFault]:
    let (bytes, game) = record(202, kinds, 200, rule, stopAt = 96)
    doAssert game.endRule == rule
    let runtime = rederive(bytes)
    doAssert runtime.sim.endRule == rule,
      "the recorded stop must be re-applied by the SAME proc, got " &
      $runtime.sim.endRule
    doAssert runtime.sim.tick == game.tick,
      "the stop tick must match: recorded " & $game.tick & ", re-derived " &
      $runtime.sim.tick
    doAssert runtime.player.hashMismatchTick == -1,
      "hash mismatch at tick " & $runtime.player.hashMismatchTick &
      " on a " & $rule & " episode"

# 29b. the OTHER pool re-derives too -----------------------------------------
check "a branchline episode re-derives on the branchline map, every end reason":
  # `newSimServer` derives the map as `pool[seed mod 3]`, so the replay has to
  # carry the POOL. With only the resolved `network` name recorded, playback
  # fell back to `defaultGameConfig().networkPool` — mainline — and rebuilt a
  # 24-train mainline world for a 16-train branchline episode.
  let kinds = [blYielder, blTimetable, blYielder, blTimetable]
  let branchNames = poolNames("branchline")
  block tickCap:
    let (bytes, game) = record(2, kinds, 120, pool = "branchline",
                               trainsPerSeat = 4)
    doAssert game.network in branchNames,
      "the recorded episode is not on a branchline map: " & game.network
    doAssert game.trains.len == 16
    let replay = parseReplayBytes(bytes)
    doAssert replay.configNode(){"networkPool"}.getStr() == "branchline",
      "the replay must record the POOL, not only the resolved network name"
    let restored = configFromReplay(replay)
    doAssert restored.networkPool == "branchline"
    doAssert restored.trainsPerSeat == 4
    let runtime = rederive(bytes)
    doAssert runtime.sim.network == game.network,
      "playback rebuilt " & runtime.sim.network & ", the episode was played " &
      "on " & game.network
    doAssert runtime.sim.trains.len == game.trains.len
    doAssert runtime.player.hashMismatchTick == -1,
      "hash mismatch at tick " & $runtime.player.hashMismatchTick &
      " on a branchline episode"
    doAssert runtime.sim.tick == game.tick
    doAssert runtime.sim.arrivedTotal == game.arrivedTotal
  for rule in [erWallClock, erFault]:
    let (bytes, game) = record(5, kinds, 200, rule, stopAt = 96,
                               pool = "branchline", trainsPerSeat = 4)
    doAssert game.network in branchNames
    doAssert game.endRule == rule
    let runtime = rederive(bytes)
    doAssert runtime.sim.network == game.network
    doAssert runtime.sim.endRule == rule
    doAssert runtime.sim.tick == game.tick
    doAssert runtime.player.hashMismatchTick == -1,
      "hash mismatch at tick " & $runtime.player.hashMismatchTick &
      " on a branchline " & $rule & " episode"

# 30. the replay is self-sufficient ------------------------------------------
check "the bytes alone carry names, aliases, kinds, config, seed and result":
  let (bytes, game) = record(303, [blYielder, blTimetable, blYielder, blTimetable],
                             120)
  let replay = parseReplayBytes(bytes)
  doAssert replay.gameName == GameName
  doAssert replay.gameVersion == GameVersion
  let config = replay.configNode()
  doAssert config{"seed"}.getBiggestInt() == 303
  doAssert config{"network"}.getStr() == game.network
  doAssert config{"num_agents"}.getInt() == 4
  doAssert config{"maxTicks"}.getInt() == 120
  doAssert replay.seatNames() == @["policy-0", "policy-1", "policy-2", "policy-3"]
  var kinds: seq[string]
  var sawDirective = false
  for node in replay.chatRecords():
    case node{"k"}.getStr()
    of "register":
      kinds.add(node{"kind"}.getStr())
      doAssert not node.hasKey("prompt"), "the register record must be REDACTED"
    of "directive":
      sawDirective = true
      doAssert node.hasKey("view"), "the directive record carries the observation"
      doAssert not node{"view"}.hasKey("your_notes")
    else: discard
  doAssert kinds.len == 4
  doAssert sawDirective
  let results = replay.resultDocument()
  doAssert results{"fleetOnTime"}.getInt() == game.fleetOnTime
  var orderRecords = 0
  for record in replay.records:
    if record.kind == rrOrders:
      inc orderRecords
  doAssert orderRecords > 0
  doAssert replay.tickCount() == game.tick

check "the observation carries your_notes and the replay's view does not":
  # The system prompt promises the seat that `notes` comes back to it next turn
  # and to nobody else (llm.nim, docs/DISPATCHING.md); the design note says the
  # replay's `directive.view` is the observation MINUS that field.
  var config = defaultGameConfig()
  config.seed = 55
  let game = newSimServer(config)
  game.startPlaying()
  game.seats[2].notes = "hold T15 until T02 clears J2"
  let view = game.seatObservation(2, 1, 31)
  doAssert view{"your_notes"}.getStr() == "hold T15 until T02 clears J2",
    "the seat's own note must come back to it"
  doAssert game.seatObservation(0, 1, 31){"your_notes"}.getStr() == "",
    "a note is echoed to its own seat only"
  let record = parseJson(directiveRecord(game, 1, 2,
                                         defaultDirective(game.testContext(2)),
                                         view))
  doAssert record{"view"}.hasKey("network_status"), "the view is mirrored"
  doAssert not record{"view"}.hasKey("your_notes"),
    "the private note must not reach the replay"
  doAssert view.hasKey("your_notes"),
    "mirroring must not strip the field out of the live observation"

# 31. replay_summary.py is strict UTF-8 JSON ---------------------------------
check "tools/replay_summary.py prints strict UTF-8 JSON at every cap":
  var config = defaultGameConfig()
  config.seed = 404
  config.maxTicks = 64
  let game = newSimServer(config)
  var writer = initReplayWriter(config.resolvedConfigJson(game.network))
  # every capped field filled to EXACTLY its cap with 4-byte emoji
  var say = ""
  for _ in 0 ..< MaxSayRunes:
    say.add("\u{1F682}")
  var notes = ""
  for _ in 0 ..< MaxNoteRunes:
    notes.add("\u{1F686}")
  var label = ""
  for _ in 0 ..< MaxPolicyLabelRunes:
    label.add("\u{1F6E4}")
  var detail = ""
  for _ in 0 ..< MaxFallbackDetailRunes:
    detail.add("\u{26A0}")
  game.startPlaying()
  for slot in 0 ..< 4:
    game.seats[slot].name = "policy-" & $slot
    writer.writeJoin(slot, game.seats[slot].name, "")
    writer.writeChat(registerRecord(slot, seatAlias(slot), label, "llm", "yielder"))
  var directive = defaultDirective(game.testContext(0))
  directive.say = sanitizeSay(say)
  directive.notes = sanitizeNote(notes)
  directive.source = dsLlm
  writer.writeChat(directiveRecord(game, 1, 0, directive,
                                   game.seatObservation(0, 1, 31)))
  writer.writeChat($(%*{"k": "fallback", "turn": 1, "slot": 1, "attempt": 2,
                        "cause": "timeout", "detail": detail}))
  var orders: seq[ReplayOrder]
  for order in directive.orders:
    orders.add(ReplayOrder(train: order.train, verb: order.verb, arg: order.arg))
  writer.writeOrders(1, 0, orders)
  while game.phase == Playing:
    game.step()
    writer.writeHash(game.tick, game.gameHash())
  writer.writeChat(resultRecord(game.networkResultsJson()))
  let path = getTempDir() / "flatland-summary-fixture.replay"
  writeFile(path, writer.finish())
  let outcome = execCmdEx("python3 " & repoRoot() / "tools" / "replay_summary.py " &
                          path)
  doAssert outcome.exitCode == 0, outcome.output
  doAssert outcome.output.validateUtf8() == -1, "the summary is not valid UTF-8"
  let summary = parseJson(outcome.output)
  doAssert summary{"protocol"}.getStr() == "flatland/v1"
  doAssert summary{"gameVersion"}.getStr() == GameVersion
  doAssert summary{"radio"}.len == 1
  doAssert summary{"radio"}[0]{"text"}.getStr().runeLen == MaxSayRunes
  doAssert summary{"fallbacks"}.getInt() == 1
  doAssert summary{"results"}{"reason"}.getStr() == "complete"
  doAssert summary{"orders"}.len == 1
  doAssert summary{"orders"}[0]{"source"}.getStr() == "llm"
  removeFile(path)

# 32. every committed fixture carries the current GameVersion ----------------
check "every committed replay fixture carries the current GameVersion":
  let dir = repoRoot() / "tests" / "replays"
  if dirExists(dir):
    var seen = 0
    for kind, path in walkDir(dir):
      if kind != pcFile or not path.endsWith(".replay"):
        continue
      inc seen
      let replay = parseReplayBytes(readFile(path))
      doAssert replay.gameVersion == GameVersion,
        path & " was recorded under GameVersion " & replay.gameVersion &
        "; re-record it in the same commit as the bump"
    doAssert seen > 0, "tests/replays/ exists but holds no fixture"

echo "test_flatland_replay: ", checks, " checks ok"
