## Sim unit tests, the network/upstream fidelity tests and the seeding and
## determinism tests. Design note §Tests 1-19.

import std/[algorithm, json, sequtils, strutils, tables, times]

import crunchy

import flatland/[sim, baselines, directives, replays, replay_runtime, roster]
import ./helpers

echo "test_flatland_sim"

let board = loadRailMap("main_a")

# 1. transition rule ---------------------------------------------------------
check "transition rule: every end but the one entered":
  for cell in board.railCells:
    let ends = board.endCount(cell)
    for d in 0 .. 3:
      let heading = Dir(d)
      if not board.hasEnd(cell, opposite(heading)):
        continue
      let exits = board.legalExits(cell, heading)
      if board.tiles[cell] == '+':
        # the flat crossing is straight only, no turning
        doAssert exits == (if board.hasEnd(cell, heading): @[heading] else: @[])
        continue
      if ends == 1:
        doAssert exits.len == 0, "a dead end must have no exits"
        continue
      var expected: seq[Dir]
      for e in 0 .. 3:
        if Dir(e) != opposite(heading) and board.hasEnd(cell, Dir(e)):
          expected.add(Dir(e))
      doAssert exits == expected, "cell " & $cell & " heading " & dirName(heading)

check "transition rule: a dead-end stub reverses":
  var found = false
  for name in ["branch_a", "branch_b", "branch_c"]:
    let map = loadRailMap(name)
    for cell in map.railCells:
      if not map.isDeadEnd(cell):
        continue
      found = true
      for d in 0 .. 3:
        if map.hasEnd(cell, opposite(Dir(d))):
          doAssert map.exitsFrom(cell, Dir(d)) == @[opposite(Dir(d))]
  doAssert found, "the branchline pool must carry a dead-end stub siding"

# 2. left / right / forward mapping ------------------------------------------
check "left/right/forward mapping and the documented repair order":
  for d in 0 .. 3:
    let heading = Dir(d)
    doAssert leftOf(heading) == Dir((d + 3) mod 4)
    doAssert rightOf(heading) == Dir((d + 1) mod 4)
  let game = emptyBoard()
  let run = game.straightRun()
  game.placeTrain(0, run.cell, run.heading)
  # MoveLeft into a straight has no left exit: repaired to MoveForward.
  let repaired = resolveExit(game.map, game.trains[0], acMoveLeft)
  doAssert repaired.dir == run.heading
  doAssert repaired.repaired
  let forward = resolveExit(game.map, game.trains[0], acMoveForward)
  doAssert forward.dir == run.heading
  doAssert not forward.repaired
  # DoNothing behaves as MoveForward for a moving train.
  doAssert resolveExit(game.map, game.trains[0], acDoNothing).dir == run.heading

check "actionsRepaired counts every repair":
  let game = emptyBoard()
  let run = game.straightRun()
  game.placeTrain(0, run.cell, run.heading, ticksPerCell = 1)
  game.trains[0].order = TrainOrder(verb: ovRun)
  let before = game.actionsRepaired
  for _ in 0 ..< 8:
    game.step()
  doAssert game.actionsRepaired >= before

# 3. speed classes -----------------------------------------------------------
check "speed classes: k ticks per cell on clear track":
  for k in 1 .. 4:
    let game = emptyBoard()
    let run = game.straightRun()
    game.placeTrain(0, run.cell, run.heading, ticksPerCell = k)
    game.trains[0].order = TrainOrder(verb: ovRun)
    discard game.map.planRoute(game.trains[0])
    let start = game.trains[0].cell
    var moved = 0
    var lastCell = start
    for _ in 0 ..< 4 * k:
      game.step()
      if game.trains[0].cell != lastCell:
        inc moved
        lastCell = game.trains[0].cell
    doAssert moved == 4, "ticksPerCell " & $k & " covered " & $moved & " cells in " &
      $(4 * k) & " ticks"

# 4 + 5. exclusive cells, no swaps, chains by handle --------------------------
check "exclusive cells: two trains never share one":
  let game = playScripted(11, [blTimetable, blTimetable, blTimetable, blTimetable])
  doAssert game.tick > 0
  var seenCell = initTable[int, int]()
  for i, train in game.trains:
    if not train.onGrid():
      continue
    doAssert not seenCell.hasKey(train.cell), "two trains on cell " & $train.cell
    seenCell[train.cell] = i

check "blocked trains accrue blockedTicks and never swap cells":
  let game = emptyBoard()
  let run = game.straightRun()
  let edge = game.map.edgeOf[run.cell]
  let cells = game.map.edges[edge].cells
  game.placeTrain(0, cells[1], game.map.edgeFwd[cells[1]])
  game.placeTrain(1, cells[2], game.map.edgeFwd[cells[2]])
  game.trains[0].order = TrainOrder(verb: ovRun)
  game.trains[1].order = TrainOrder(verb: ovHold)
  game.trains[0].route = @[cells[2]]
  let (a, b) = (game.trains[0].cell, game.trains[1].cell)
  game.step()
  doAssert game.trains[1].cell == b, "a held train must not move"
  doAssert not (game.trains[0].cell == b and game.trains[1].cell == a),
    "trains may never swap cells"
  doAssert game.trains[0].blockedTicks >= 1 or game.trains[0].cell != a

check "blocked_ticks_last_turn counts THIS turn's refusals, not the episode's":
  let game = emptyBoard()
  let run = game.straightRun()
  let cells = game.map.edges[game.map.edgeOf[run.cell]].cells
  doAssert cells.len >= 3
  game.placeTrain(0, cells[2], game.map.edgeFwd[cells[2]])
  game.placeTrain(1, cells[1], game.map.edgeFwd[cells[1]])
  game.trains[0].order = TrainOrder(verb: ovHold)
  game.trains[1].order = TrainOrder(verb: ovRun)
  game.trains[1].route = @[cells[2]]
  for _ in 0 ..< 5:
    game.step()
  game.closeTurn()
  doAssert game.trains[1].blockedLastTurn == 5,
    "turn 1 refused it 5 times, reported " & $game.trains[1].blockedLastTurn
  doAssert game.trains[1].blockedTicks == 5
  for _ in 0 ..< 3:
    game.step()
  game.closeTurn()
  doAssert game.trains[1].blockedTicks == 8, "the episode total keeps counting"
  doAssert game.trains[1].blockedLastTurn == 3,
    "blocked_ticks_last_turn is LAST TURN, not the episode-to-date total: " &
    $game.trains[1].blockedLastTurn
  doAssert game.seatObservation(0, 2, 31){"your_trains"}[1]{
    "blocked_ticks_last_turn"}.getInt() == 3
  # a turn in which nothing was refused reports zero, not the old total
  game.trains[1].order = TrainOrder(verb: ovHold)
  game.step()
  game.closeTurn()
  doAssert game.trains[1].blockedLastTurn == 0

# 6. dead end ----------------------------------------------------------------
check "dead end: the train reverses and steps back":
  let map = loadRailMap("branch_a")
  var stub = -1
  for cell in map.railCells:
    if map.isDeadEnd(cell):
      stub = cell
      break
  doAssert stub >= 0
  var heading = Dir(0)
  for d in 0 .. 3:
    if map.hasEnd(stub, opposite(Dir(d))):
      heading = Dir(d)
  let exit = map.exitsFrom(stub, heading)
  doAssert exit == @[opposite(heading)]

# 7. segment interlock -------------------------------------------------------
check "segment interlock refuses an opposing entry and admits a follower":
  let game = emptyBoard()
  # find a single-track edge with room for two trains
  var target = -1
  for id, edge in game.map.edges:
    if edge.parallel or edge.cells.len < 4:
      continue
    target = id
    break
  doAssert target >= 0, "the mainline board must carry a single-track section"
  let cells = game.map.edges[target].cells
  # a train travelling A->B sits in the middle
  game.placeTrain(0, cells[2], game.map.edgeFwd[cells[2]])
  game.trains[0].order = TrainOrder(verb: ovHold)
  # an opposing train at the far node tries to enter
  let farNode = game.map.edges[target].nodeB
  game.placeTrain(1, farNode, opposite(game.map.edgeFwd[cells[^1]]))
  game.trains[1].order = TrainOrder(verb: ovRun)
  game.trains[1].route = @[cells[^1]]
  let before = game.trains[1].cell
  game.step()
  doAssert game.trains[1].cell == before, "an opposing entry must be refused"
  doAssert game.waitsFor[1] == 0, "the refused train waits for the opposing one"
  # a follower travelling the SAME way is admitted
  let follower = game.map.edges[target].nodeA
  game.placeTrain(2, follower, game.map.edgeFwd[cells[0]])
  game.trains[2].order = TrainOrder(verb: ovRun)
  game.trains[2].route = @[cells[0]]
  game.step()
  doAssert game.trains[2].cell == cells[0], "a same-direction follower is admitted"

# 8. malfunctions are a pure hash --------------------------------------------
check "malfunctions are a pure hash of (seed, train, tick)":
  proc table(seed: uint64): seq[(int, int, int)] =
    for train in 0 ..< 24:
      for tick in 1 .. 496:
        let d = malfunctionDraw(seed, train, tick, 300, 8, 24)
        if d > 0:
          result.add((train, tick, d))
  let a = table(4242)
  let b = table(4242)
  doAssert a == b, "the table must be a pure function of the seed"
  doAssert a.len > 0, "seed 4242 must draw at least one breakdown"
  doAssert table(4243) != a, "a different seed must draw a different table"

check "malfunctions are unsteerable by seat behaviour":
  proc drawsOf(kinds: array[4, Baseline]): seq[(int, int)] =
    let game = playScripted(9, kinds)
    for event in game.events:
      if event.kind == Malfunction:
        result.add((event.train, event.tick))
  # The DRAW table is what must be identical: which trains are running when
  # their number comes up is legitimately a dispatcher's business, so compare
  # the pure table rather than the realised events.
  proc pure(): seq[(int, int)] =
    for train in 0 ..< 24:
      for tick in 1 .. 496:
        if malfunctionDraw(9, train, tick, 300, 8, 24) > 0:
          result.add((train, tick))
  let table = pure()
  for realised in [drawsOf([blYielder, blYielder, blYielder, blYielder]),
                   drawsOf([blTimetable, blTimetable, blTimetable, blTimetable])]:
    for entry in realised:
      doAssert entry in table, "a realised breakdown was not in the pure table"

check "a malfunctioning train blocks its cell and cannot be repaired early":
  let game = emptyBoard()
  let run = game.straightRun()
  game.placeTrain(0, run.cell, run.heading)
  game.trains[0].state = tsMalfunctioning
  game.trains[0].malfunctionLeft = 6
  let cell = game.trains[0].cell
  for _ in 0 ..< 5:
    game.step()
    doAssert game.trains[0].cell == cell, "a broken train must not move"
    doAssert game.trains[0].state == tsMalfunctioning

# 9. departures --------------------------------------------------------------
check "departures: off the grid, not before the clock, never while held":
  let game = emptyBoard()
  game.trains[0].state = tsWaiting
  game.trains[0].cell = -1
  game.trains[0].earliestDeparture = 6
  game.trains[0].order = TrainOrder(verb: ovHold)
  for _ in 0 ..< 10:
    game.step()
    doAssert game.trains[0].cell == -1, "a held waiting train must not depart"
  game.trains[0].order = TrainOrder(verb: ovRun)
  game.step()
  doAssert game.trains[0].cell == game.trains[0].startCell
  doAssert game.occ.at(game.trains[0].cell) == 0

check "departures wait for a free platform cell":
  let game = emptyBoard()
  game.trains[0].state = tsWaiting
  game.trains[0].cell = -1
  game.trains[0].earliestDeparture = 0
  game.trains[0].order = TrainOrder(verb: ovRun)
  game.placeTrain(1, game.trains[0].startCell, Dir(0))
  game.trains[1].order = TrainOrder(verb: ovHold)
  game.step()
  doAssert game.trains[0].cell == -1, "the platform is occupied"

# 10. arrival and removal ----------------------------------------------------
check "arrival removes the train, frees the cell and sets onTime honestly":
  let game = emptyBoard()
  let station = game.trains[0].target
  let platform = game.map.stationCells[station][0]
  var approach = -1
  var heading = Dir(0)
  for d in 0 .. 3:
    if not game.map.hasEnd(platform, Dir(d)):
      continue
    let prev = game.map.step(platform, Dir(d))
    if prev >= 0 and game.map.isRail(prev) and
        not game.map.routingBlocked(prev, platform, opposite(Dir(d))):
      approach = prev
      heading = opposite(Dir(d))
  doAssert approach >= 0
  game.placeTrain(0, approach, heading)
  game.trains[0].order = TrainOrder(verb: ovRun)
  game.trains[0].route = @[platform]
  game.trains[0].scheduledArrival = 4096
  game.step()
  doAssert game.trains[0].state == tsArrived
  doAssert game.trains[0].cell == -1
  doAssert game.occ.at(platform) == -1
  doAssert game.trains[0].onTime
  doAssert game.arrivedTotal == 1 and game.fleetOnTime == 1

check "reaching the WRONG station's platform does nothing":
  let game = emptyBoard()
  var other = (game.trains[0].target + 1) mod 8
  let platform = game.map.stationCells[other][0]
  game.placeTrain(0, platform, game.map.platformOutboundHeading(platform))
  game.trains[0].order = TrainOrder(verb: ovHold)
  game.step()
  doAssert game.trains[0].state != tsArrived
  doAssert game.arrivedTotal == 0

# 11. jam vs deadlock --------------------------------------------------------
check "jam vs deadlock: a queue behind a broken train is never a deadlock":
  let game = emptyBoard()
  let run = game.straightRun()
  let cells = game.map.edges[game.map.edgeOf[run.cell]].cells
  doAssert cells.len >= 3
  game.placeTrain(0, cells[0], game.map.edgeFwd[cells[0]])
  game.trains[0].state = tsMalfunctioning
  game.trains[0].malfunctionLeft = 400
  for slot, cell in [cells[1], cells[2]]:
    game.placeTrain(slot + 1, cell, opposite(game.map.edgeFwd[cell]))
    game.trains[slot + 1].order = TrainOrder(verb: ovRun)
    game.trains[slot + 1].route = @[if slot == 0: cells[0] else: cells[0]]
  for _ in 0 ..< 40:
    game.step()
  doAssert game.deadlocks == 0,
    "a queue behind a malfunctioning train is a delay, not a deadlock"

check "a single stalled train is neither a jam nor a deadlock":
  let game = emptyBoard()
  let run = game.straightRun()
  game.placeTrain(0, run.cell, run.heading)
  game.trains[0].order = TrainOrder(verb: ovHold)
  for _ in 0 ..< 40:
    game.step()
  doAssert game.activeJam.len == 0 and game.activeDeadlock.len == 0

check "a real episode reaches a permanent deadlock and reports it":
  let game = playScripted(42, [blTimetable, blTimetable, blTimetable, blTimetable])
  doAssert game.deadlocks > 0, "greedy play must be able to deadlock the network"
  doAssert game.deadlockTicks > 0
  var report = parseJson(game.networkResultsJson())
  doAssert report{"deadlocks"}.getInt() == game.deadlocks

check "deadlockCells names the cells the cycle is fighting over":
  # A closed waits-for cycle: every member is refused the cell its successor is
  # standing on, so the set of cells the cycle is fighting over IS the set of
  # cells its members hold. Pinned here so "the members' own cells" can never
  # drift away from "the contested cells" the note and the viewer promise.
  let game = emptyBoard()
  let run = game.straightRun()
  let cells = game.map.edges[game.map.edgeOf[run.cell]].cells
  doAssert cells.len >= 3
  game.placeTrain(0, cells[1], game.map.edgeFwd[cells[1]])
  game.placeTrain(1, cells[2], opposite(game.map.edgeFwd[cells[2]]))
  for i in 0 .. 1:
    game.trains[i].order = TrainOrder(verb: ovRun)
  game.trains[0].route = @[cells[2]]
  game.trains[1].route = @[cells[1]]
  for _ in 0 ..< game.config.deadlockTicks + 1:
    game.step()
  doAssert game.activeDeadlock == @[0, 1], $game.activeDeadlock
  doAssert game.waitsFor[0] == 1 and game.waitsFor[1] == 0
  var members: seq[int]
  var contested: seq[int]
  for train in game.activeDeadlock:
    members.add(game.trains[train].cell)
    contested.add(game.trains[game.waitsFor[train]].cell)
  members.sort()
  contested.sort()
  doAssert members == contested,
    "in a cycle the cells wanted and the cells held are the same set"
  var reported = game.deadlockCells
  reported.sort()
  doAssert reported == members, $reported & " vs " & $members
  doAssert reported.len == 2
  # and the viewer and the observation are handed exactly those cells
  let seen = game.seatObservation(0, 1, 31){"network_status"}{"deadlock_cells"}
  doAssert seen.len == 2

# 12. scoring ----------------------------------------------------------------
check "scoring: the formula, the sign and the lexicographic bound":
  var rng = initRng(7)
  for _ in 0 ..< 500:
    let game = emptyBoard()
    game.arrivedTotal = rng.rand(25)
    game.fleetOnTime = rng.rand(game.arrivedTotal + 1)
    for s in 0 ..< 4:
      game.arrived[s] = rng.rand(7)
      game.onTime[s] = rng.rand(game.arrived[s] + 1)
    for s in 0 ..< 4:
      doAssert game.scoreFor(s) ==
        1000 * game.fleetOnTime + 10 * game.arrivedTotal + game.onTime[s]
      doAssert game.scoreFor(s) >= 0
      doAssert game.onTime[s] < 10, "the tie-break term must stay an epsilon"
    doAssert 10 * game.arrivedTotal < 1000, "the arrivals term must not invert par"

check "win is one shared boolean and winner is null":
  let game = playScripted(3, [blYielder, blTimetable, blYielder, blTimetable])
  let results = parseJson(game.networkResultsJson())
  doAssert results{"winner"}.kind == JNull
  let win = results{"win"}
  doAssert win.len == 4
  for entry in win:
    doAssert entry.getBool() == win[0].getBool()

# 13. end conditions ---------------------------------------------------------
check "end conditions: allArrived, quiescent, tickCap, wallClock, fault":
  block allArrived:
    let game = emptyBoard()
    doAssert game.allArrived()
    game.step()
    doAssert game.endRule == erAllArrived and game.reason == reComplete
  block quiescent:
    let game = emptyBoard()
    game.trains[0].state = tsWaiting
    game.trains[0].cell = -1
    game.trains[0].earliestDeparture = 100000
    game.arrivedTotal = 0
    for _ in 0 ..< 200:
      if game.phase != Playing: break
      game.step()
    doAssert game.endRule == erQuiescent and game.reason == reComplete
  block tickCap:
    let game = playScripted(5, [blYielder, blYielder, blYielder, blYielder])
    doAssert game.endRule in {erTickCap, erAllArrived, erQuiescent}
    doAssert game.reason == reComplete
  block wallClock:
    let game = emptyBoard()
    game.trains[0].state = tsRunning
    game.stopAtWallClock()
    doAssert game.endRule == erWallClock and game.reason == reDeadline
  block fault:
    let game = emptyBoard()
    game.trains[0].state = tsRunning
    game.faultStop("synthetic")
    doAssert game.endRule == erFault and game.reason == reFault
    doAssert game.stopDetail == "synthetic"

# 14. no floating point in the sim -------------------------------------------
check "no floating point in the sim":
  for name in ["sim", "railmap", "trains", "deadlock", "driver", "baselines"]:
    let source = readRepoFile("src/flatland/" & name & ".nim")
    let hits = countFloatSyntax(source)
    doAssert hits.len == 0, "src/flatland/" & name & ".nim is not integer-only:\n" &
      hits.join("\n") & "\nthe native <-> wasm hash chain must be integer only"

# 15. tick budget ------------------------------------------------------------
check "496 ticks of a full 24-train episode are fast":
  let start = epochTime()
  discard playScripted(21, [blYielder, blTimetable, blYielder, blTimetable])
  let elapsed = epochTime() - start
  doAssert elapsed < 20.0, "an episode took " & $elapsed & "s"

# 16. the committed networks -------------------------------------------------
check "every committed .rail file loads, validates and is pinned":
  let pins = parseJson(readRepoFile("tests/rail_sha256.json"))
  for entry in RailFiles:
    let map = loadRailMap(entry.name)
    doAssert map.width == 28 and map.height == 14
    for station in 0 ..< map.stationCells.len:
      doAssert map.stationCells[station].len == 3
    doAssert map.stationsReachable()
    var interior = 0
    for cell in map.railCells:
      if map.isNode[cell]:
        continue
      doAssert map.edgeOf[cell] >= 0
      inc interior
    doAssert interior > 0
    if entry.pool == "mainline":
      doAssert map.parallelPairs() >= 4,
        entry.name & " has " & $map.parallelPairs() & " double-track pairs"
    else:
      doAssert map.parallelPairs() == 5,
        entry.name & " has " & $map.parallelPairs() & " passing loops"
    let want = pins{entry.name}.getStr()
    let got = toHex(sha256(entry.text))
    doAssert want == got,
      entry.name & ".rail sha256 is " & got & ", pinned " & want &
      " — a map change is a GameVersion bump"

check "every station and label sits on rail, ids are the published lists":
  for entry in RailFiles:
    let map = loadRailMap(entry.name)
    for j in 0 ..< JunctionIds.len:
      doAssert map.junctionCell[j] >= 0
      doAssert map.isRail(map.junctionCell[j])
    for s in 0 ..< SidingIds.len:
      doAssert map.sidingEdge[s] >= 0
      doAssert map.sidingCells(s).len > 0

# 17. upstream fidelity ------------------------------------------------------
check "the shipped upstream constants equal the cited table":
  doAssert ActionDoNothing == 0 and ActionMoveLeft == 1 and
    ActionMoveForward == 2 and ActionMoveRight == 3 and ActionStopMoving == 4
  doAssert DirNorth == 0 and DirEast == 1 and DirSouth == 2 and DirWest == 3
  doAssert Connectivity == 4 and not GridWraps
  doAssert CellsAreExclusive and DeadEndReverses and MoveOrderIsByHandle
  doAssert MalfunctionsBlockOthers and MalfunctionsCannotBeRepairedEarly
  doAssert RemoveAgentsAtTarget
  doAssert SpeedClasses == [1, 2, 3, 4]
  doAssert SpeedClasses.len <= MaxSpeedProfiles
  doAssert upstreamMaxTimeSteps(28, 14) == 496
  doAssert DefaultMaxTicks == 496

# 18. seeding ----------------------------------------------------------------
check "the network is pool[seed mod 3] and nothing a seat does changes the draw":
  for seed in 0'u64 .. 8'u64:
    let names = poolNames("mainline")
    doAssert networkForSeed("mainline", seed) == names[int(seed mod 3)]
  proc drawOf(kinds: array[4, Baseline]): seq[(int, int, int, int, int)] =
    var config = defaultGameConfig()
    config.seed = 17
    let game = newSimServer(config)
    for i, train in game.trains:
      result.add((train.startCell, int(train.startHeading), train.target,
                  train.ticksPerCell, train.earliestDeparture))
  let a = drawOf([blYielder, blYielder, blYielder, blYielder])
  let b = drawOf([blTimetable, blTimetable, blTimetable, blTimetable])
  doAssert a == b, "the reset draw must not depend on seat behaviour"

check "start platforms are distinct, targets are reachable and long enough":
  var config = defaultGameConfig()
  config.seed = 31
  let game = newSimServer(config)
  var starts: seq[int]
  var speeds: seq[int]
  var ranks: seq[int]
  for train in game.trains:
    doAssert train.startCell notin starts
    starts.add(train.startCell)
    doAssert train.target != game.map.stationOf[train.startCell]
    doAssert train.plannedCells >= config.minJourneyCells
    speeds.add(train.ticksPerCell)
    doAssert train.earliestDeparture mod config.departStagger == 0
    ranks.add(train.earliestDeparture div config.departStagger)
  speeds.sort()
  doAssert speeds == speedMultiset(game.trains.len).sorted()
  ranks.sort()
  doAssert ranks == toSeq(0 ..< game.trains.len)

# 19. determinism ------------------------------------------------------------
check "re-simulating from the recorded orders reproduces every tick hash":
  let live = playScripted(77, [blYielder, blTimetable, blYielder, blTimetable])
  var writer = initReplayWriter(live.config.resolvedConfigJson(live.network))
  for slot in 0 ..< live.seatCount():
    writer.writeJoin(slot, live.seats[slot].name, "")
  # replay the same episode through the recorder
  let recorded = newSimServer(live.config)
  recorded.startPlaying()
  while recorded.phase == Playing:
    if recorded.tick mod recorded.config.turnTicks == 0:
      let turn = (recorded.tick div recorded.config.turnTicks) + 1
      let world = recorded.testWorld()
      for seat in 0 ..< 4:
        let kinds = [blYielder, blTimetable, blYielder, blTimetable]
        let directive = scriptedDirective(world, kinds[seat], recorded.testContext(seat))
        var orders: seq[ReplayOrder]
        for order in directive.orders:
          recorded.applyOrder(order.train, TrainOrder(verb: order.verb, arg: order.arg))
          orders.add(ReplayOrder(train: order.train, verb: order.verb, arg: order.arg))
        writer.writeOrders(turn, seat, orders)
    recorded.step()
    writer.writeHash(recorded.tick, recorded.gameHash())
  doAssert recorded.tick == live.tick
  doAssert recorded.arrivedTotal == live.arrivedTotal
  doAssert recorded.fleetOnTime == live.fleetOnTime

  let bytes = writer.finish()
  var runtime = initReplayRuntime(parseReplayBytes(bytes))
  while runtime.sim.phase == Playing and not runtime.player.finished:
    runtime.advanceReplayFrame()
  doAssert runtime.player.hashMismatchTick == -1,
    "hash mismatch at tick " & $runtime.player.hashMismatchTick
  doAssert runtime.sim.tick == live.tick
  doAssert runtime.sim.arrivedTotal == live.arrivedTotal
  doAssert runtime.sim.fleetOnTime == live.fleetOnTime

echo "test_flatland_sim: ", checks, " checks ok"
