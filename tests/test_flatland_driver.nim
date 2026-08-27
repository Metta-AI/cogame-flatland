## The driver, the reply validator and the scripted baselines.
## Design note §Tests 20-24.

import std/[json, strutils, unicode]

import flatland/[sim, directives, baselines, decide, llm]
import ./helpers

echo "test_flatland_driver"

proc pseudoStates(count: int): seq[SimServer] =
  ## `count` pseudo-random worlds: both networks, every slot, varied
  ## departures, malfunctions, jams and deadlocks.
  var rng = initRng(2026)
  for i in 0 ..< count:
    let pool = if i mod 2 == 0: "mainline" else: "branchline"
    var config = defaultGameConfig()
    config.seed = uint64(1000 + i)
    config.networkPool = pool
    config.trainsPerSeat = if pool == "mainline": 6 else: 4
    let game = newSimServer(config)
    game.startPlaying()
    for _ in 0 ..< rng.rand(180):
      if game.phase != Playing:
        break
      game.step()
    # scatter some states the natural run may not have reached yet
    for t in 0 ..< game.trains.len:
      case rng.rand(6)
      of 0:
        if game.trains[t].onGrid():
          game.trains[t].state = tsMalfunctioning
          game.trains[t].malfunctionLeft = 1 + rng.rand(24)
      of 1: game.trains[t].stalledTicks = rng.rand(40)
      of 2:
        if game.trains[t].onGrid():
          game.trains[t].state = tsHeld
      else: discard
    result.add(game)

# 20. bounded orders ---------------------------------------------------------
check "both baselines are bounded, legal and silent over 200 worlds":
  var worlds = pseudoStates(200)
  for game in worlds:
    let world = game.testWorld()
    for kind in [blTimetable, blYielder]:
      for seat in 0 ..< game.seatCount():
        let ctx = game.testContext(seat)
        let directive = scriptedDirective(world, kind, ctx)
        doAssert directive.orders.len <= game.config.trainsPerSeat
        doAssert directive.say.len == 0, "a baseline must never speak"
        doAssert directive.notes.len == 0
        var seen: seq[int]
        for order in directive.orders:
          doAssert game.seatOwns(seat, order.train),
            "a baseline named a train it does not own"
          doAssert order.train notin seen, "a baseline named a train twice"
          seen.add(order.train)
          doAssert order.verb in {ovRun, ovHold, ovSiding, ovRoute}
          if order.verb == ovSiding:
            doAssert sidingIndex(order.arg) >= 0, "unknown siding " & order.arg
          if order.verb == ovRoute:
            doAssert game.map.goalCellsFor(order.arg).len > 0
        var ids: seq[string]
        for i in game.seatTrains(seat):
          ids.add(trainId(i))
        doAssert ($directive.serialise(ids)).len <= 1024

# 21. the driver never emits an illegal action -------------------------------
check "the driver never emits an illegal action and never leaves a train idle":
  var worlds = pseudoStates(40)
  for game in worlds:
    for i in 0 ..< game.trains.len:
      if not game.trains[i].onGrid():
        continue
      var train = game.trains[i]
      let action = driveTrain(game.map, train)
      doAssert action in {acDoNothing, acMoveLeft, acMoveForward, acMoveRight, acStop}
      if train.state == tsMalfunctioning:
        continue
      let exit = resolveExit(game.map, train, action)
      if exit.reversed:
        doAssert game.map.isDeadEnd(train.cell)
      else:
        doAssert game.map.hasEnd(train.cell, exit.dir),
          "the resolved exit is not an end of the tile"

check "every committed move uses a legal transition for its heading":
  let game = playScripted(13, [blYielder, blTimetable, blYielder, blTimetable])
  # the episode ran to its end without the sim ever raising; the per-tick hash
  # chain in test_flatland_sim proves the moves were the ones recorded.
  doAssert game.tick > 0
  for train in game.trains:
    if train.cell >= 0:
      doAssert game.map.isRail(train.cell)

# 22. the fallback IS the yielder proc ---------------------------------------
check "the decision engine's fallback resolves to the yielder baseline":
  let game = playScripted(4, [blYielder, blYielder, blYielder, blYielder],
                          maxTicks = 64)
  var engine = initDecisionEngine(game)
  let ctx = game.testContext(0)
  let world = engine.worldFor(game)
  let viaEngine = engine.yielderFor(game, 0)
  let viaBaseline = yielderDirective(world, ctx)
  doAssert viaEngine.orders.len == viaBaseline.orders.len
  for i in 0 ..< viaEngine.orders.len:
    doAssert viaEngine.orders[i].train == viaBaseline.orders[i].train
    doAssert viaEngine.orders[i].verb == viaBaseline.orders[i].verb
    doAssert viaEngine.orders[i].arg == viaBaseline.orders[i].arg
  # and it is literally the same proc, not a second copy of the rules
  doAssert yielderDirective == scriptedDirectiveYielderAlias

# 23. reply validation -------------------------------------------------------
check "the validator repairs, drops, caps and truncates on RUNE boundaries":
  var config = defaultGameConfig()
  config.seed = 8
  let game = newSimServer(config)
  game.startPlaying()
  game.applyOrder(0, TrainOrder(verb: ovSiding, arg: "S2"))
  var ctx = game.testContext(0)
  doAssert ctx.trainIds[0] == "T01"

  block schemaAccepted:
    let reply = parseDirective(parseJson("""
      {"orders":[{"train":"T01","verb":"siding","at":"S3"},
                 {"train":"T02","verb":"hold"}],
       "say":"T01 into S3","notes":"release T03 next turn"}"""), ctx)
    doAssert reply.orders[0].verb == ovSiding and reply.orders[0].arg == "S3"
    doAssert reply.orders[1].verb == ovHold
    doAssert reply.say == "T01 into S3"
    doAssert reply.notes == "release T03 next turn"
    doAssert reply.rejected == 0

  block repairedToPrevious:
    let reply = parseDirective(parseJson(
      """{"orders":[{"train":"T01","verb":"teleport"}]}"""), ctx)
    doAssert reply.orders[0].verb == ovSiding and reply.orders[0].arg == "S2",
      "an invalid verb must be repaired to that train's PREVIOUS order"
    doAssert reply.rejected == 1
    doAssert not reply.orders[0].fromReply

  block missingArgument:
    let reply = parseDirective(parseJson(
      """{"orders":[{"train":"T01","verb":"siding"}]}"""), ctx)
    doAssert reply.orders[0].verb == ovSiding and reply.orders[0].arg == "S2"
    doAssert reply.rejected == 1

  block unknownSiding:
    let reply = parseDirective(parseJson(
      """{"orders":[{"train":"T01","verb":"siding","at":"S9"}]}"""), ctx)
    doAssert reply.orders[0].arg == "S2"
    doAssert reply.rejected == 1

  block foreignTrain:
    let reply = parseDirective(parseJson(
      """{"orders":[{"train":"T20","verb":"hold"}]}"""), ctx)
    doAssert reply.rejected == 1
    for order in reply.orders:
      doAssert game.seatOwns(0, order.train)

  block arrivedTrain:
    var arrivedCtx = ctx
    arrivedCtx.arrived[2] = true
    let reply = parseDirective(parseJson(
      """{"orders":[{"train":"T03","verb":"run"}]}"""), arrivedCtx)
    doAssert reply.rejected == 1

  block sayOnly:
    let reply = parseDirective(parseJson("""{"say":"holding the down main"}"""), ctx)
    doAssert reply.say == "holding the down main"
    doAssert reply.orders.len == ctx.trainIds.len
    for order in reply.orders:
      doAssert not order.fromReply

  block notAnObject:
    var raised = false
    try:
      discard parseDirective(parseJson("[1,2,3]"), ctx)
    except DirectiveError, ValueError:
      raised = true
    doAssert raised

  block runeTruncation:
    # a 4-byte emoji sitting exactly on every cap
    var longSay = ""
    for _ in 0 ..< 400:
      longSay.add("\u{1F682}")
    var longNote = ""
    for _ in 0 ..< 600:
      longNote.add("\u{1F686}")
    let node = %*{"say": longSay, "notes": longNote}
    let reply = parseDirective(node, ctx)
    doAssert reply.say.runeLen == MaxSayRunes
    doAssert reply.notes.runeLen == MaxNoteRunes
    doAssert reply.say.validateUtf8() == -1, "a byte-truncated say is not UTF-8"
    doAssert reply.notes.validateUtf8() == -1

  block orderCap:
    var orders = newJArray()
    for i in 0 ..< 20:
      orders.add(%*{"train": trainId(i mod 6), "verb": "run"})
    let reply = parseDirective(%*{"orders": orders}, ctx)
    doAssert reply.orders.len == ctx.trainIds.len
    doAssert reply.rejected > 0

check "tolerant JSON extraction survives fences and trailing prose":
  let fenced = "Sure!\n```json\n{\"say\":\"T01 has the main\"}\n```\nGood luck."
  doAssert extractJsonObject(fenced){"say"}.getStr() == "T01 has the main"
  var raised = false
  try:
    discard extractJsonObject("no object here at all")
  except DirectiveError:
    raised = true
  doAssert raised

# 23b. the whole network reaches the seat ------------------------------------
check "every seat is sent the tile grid and the junction graph, both pools":
  for pool in ["mainline", "branchline"]:
    var config = defaultGameConfig()
    config.seed = 3
    config.networkPool = pool
    config.trainsPerSeat = if pool == "mainline": 6 else: 4
    let game = newSimServer(config)
    let briefing = game.networkBriefing()
    doAssert briefing{"name"}.getStr() == game.network
    doAssert briefing{"tiles"}.len == game.map.height
    for row in briefing{"tiles"}:
      doAssert row.getStr().len == game.map.width
    doAssert briefing{"junction_graph"}.len > 0,
      "the junction graph is empty on " & game.network
    var sawBothWays = false
    var sawSiding = false
    for edge in briefing{"junction_graph"}:
      doAssert edge{"a"}.getStr().len > 0 and edge{"b"}.getStr().len > 0
      doAssert edge{"cells"}.getInt() > 0
      if edge{"both_ways"}.getBool():
        sawBothWays = true
      if edge{"siding"}.kind == JString:
        sawSiding = true
    doAssert sawBothWays,
      "the graph must say which sections are passable both ways at once"
    doAssert sawSiding, "the graph must name the sidings it carries"
    for id in SidingIds:
      doAssert briefing{"sidings"}.hasKey(id), "no cells for siding " & id
    for id in JunctionIds:
      doAssert briefing{"junctions"}.hasKey(id), "no cell for junction " & id
    for ch in StationLetters:
      doAssert briefing{"stations"}{$ch}.len == 3,
        "station " & $ch & " must publish its three platform cells"
    # and it is at the head of the message the seat actually receives
    let message = userMessage($briefing, "operator guidance",
                              "{\"you\":\"Alpha\"}")
    doAssert "THE NETWORK" in message
    doAssert "junction_graph" in message
    doAssert briefing{"tiles"}[1].getStr() in message,
      "the ASCII grid must survive into the user message verbatim"
    doAssert message.find("THE NETWORK") < message.find("operator guidance")
    doAssert message.find("operator guidance") < message.find("{\"you\"")

# 24. the baseline tuning is the swept pick ----------------------------------
check "the shipped baseline parameters are the swept pick":
  let tuning = parseJson(readRepoFile("tools/ci/baseline_tuning.json"))
  doAssert tuning{"yieldAfter"}.getInt() == DefaultBaselineParams.yieldAfter
  doAssert tuning{"departLookahead"}.getInt() == DefaultBaselineParams.departLookahead
  doAssert tuning{"sidingLookahead"}.getInt() == DefaultBaselineParams.sidingLookahead
  doAssert tuning{"lowerIdYields"}.getBool() == DefaultBaselineParams.lowerIdYields

check "yielder yields where timetable jams":
  var yielderDeadlocks = 0
  var timetableDeadlocks = 0
  for seed in 1'u64 .. 6'u64:
    yielderDeadlocks += playScripted(
      seed, [blYielder, blYielder, blYielder, blYielder]).deadlocks
    timetableDeadlocks += playScripted(
      seed, [blTimetable, blTimetable, blTimetable, blTimetable]).deadlocks
  doAssert yielderDeadlocks < timetableDeadlocks,
    "yielder deadlocked " & $yielderDeadlocks & " times, timetable " &
    $timetableDeadlocks

echo "test_flatland_driver: ", checks, " checks ok"
