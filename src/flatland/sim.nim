## The sim: the whole physics of the game, and nothing else mutates the world.
##
## Imports and re-exports the sim modules, as the starter's `src/ctf/sim.nim`
## does, so `import flatland/sim` sees everything. The SAME module compiles
## twice: natively into `/bin/flatland` and to wasm through
## `replay-viewer/config.nims`, which is what makes the replay's per-tick hash
## chain exact.

import std/json

import sim_types, upstream, sim_config, railmap, trains, driver, deadlock
export sim_types, upstream, sim_config, railmap, trains, driver, deadlock

type
  SimEventKind* = enum
    ## The tier-2 analysis stream's closed enum (`COGAME_EVENTS_URI`).
    Depart, Arrive, Malfunction, Repaired, Blocked, Jam, JamClear,
    Deadlock, DeadlockClear, TurnStart, DirectiveIssued, FallbackTaken, PhaseChange

  SimEvent* = object
    tick*: int
    kind*: SimEventKind
    train*: int
    slot*: int
    cell*: int
    amount*: int
    station*: int
    trains*: seq[int]
    content*: string

  Seat* = object
    name*: string          ## the REAL policy/player name — spectator side only
    token*: string
    joined*: bool
    dead*: bool
    kind*: string          ## "llm" | "scripted"
    baseline*: string
    policyLabel*: string
    llmTurns*: int
    fallbackTurns*: int
    ordersRejected*: int
    radio*: string         ## this seat's last `say`
    notes*: string         ## private, echoed back to this seat only

  SimServer* = ref object
    config*: GameConfig
    map*: RailMap
    network*: string
    trains*: seq[Train]
    occ*: Occupancy
    seats*: seq[Seat]

    tick*: int
    turn*: int
    phase*: GamePhase
    reason*: EndReason
    endRule*: EndRule
    stopDetail*: string
    gameOverTicksLeft*: int
    lobbyTicks*: int

    hashValue*: uint64
    hashes*: seq[uint64]

    events*: seq[SimEvent]      ## the tier-2 stream, whole episode
    frameEvents*: seq[SimEvent] ## derived broadcast events for this tick

    arrivedTotal*: int
    fleetOnTime*: int
    arrived*: array[MaxSeats, int]
    onTime*: array[MaxSeats, int]
    latenessTicks*: array[MaxSeats, int]
    deadlocks*: int
    deadlockTicks*: int
    jams*: int
    jamTicks*: int
    longestJamTicks*: int
    currentJamRun*: int
    malfunctions*: int
    malfunctionTicks*: int
    actionsRepaired*: int
    stranded*: int
    terminalDeadlock*: bool

    activeJam*: seq[int]
    activeDeadlock*: seq[int]
    deadlockCells*: seq[int]
    jamStartTick*: int
    deadlockStartTick*: int
    quietTicks*: int
    waitsFor*: seq[int]

    feedDirectives*: seq[string]  ## `directive` records for the broadcast feed

proc trainCount*(sim: SimServer): int {.inline.} = sim.trains.len
proc seatCount*(sim: SimServer): int {.inline.} = sim.config.numAgents

proc emit(sim: SimServer, event: SimEvent) =
  sim.events.add(event)
  sim.frameEvents.add(event)

proc newSimServer*(config: GameConfig): SimServer =
  ## Builds the world from the resolved config. The network is
  ## `pool[seed mod 3]`; every other seeded draw follows in `setupTrains`.
  var cfg = config
  cfg.validate()
  result = SimServer(config: cfg)
  result.network = networkForSeed(cfg.networkPool, cfg.seed)
  result.map = loadRailMap(result.network)
  result.trains = setupTrains(result.map, cfg)
  result.occ = initOccupancy(result.map)
  result.seats = newSeq[Seat](cfg.numAgents)
  for i in 0 ..< result.seats.len:
    result.seats[i].kind = "scripted"
    result.seats[i].baseline = "yielder"
    result.seats[i].policyLabel = "yielder"
    result.seats[i].name =
      if i < cfg.playerNames.len and cfg.playerNames[i].len > 0:
        cfg.playerNames[i]
      else:
        seatAlias(i)
  result.phase = Lobby
  result.reason = reComplete
  result.endRule = erTickCap
  result.waitsFor = newSeq[int](result.trains.len)
  result.jamStartTick = -1
  result.deadlockStartTick = -1
  result.hashValue = 0xC0FFEE1234567'u64 xor cfg.seed

# ---------------------------------------------------------------------------
#  Hashing
# ---------------------------------------------------------------------------

proc mixHash(sim: SimServer, value: int) {.inline.} =
  sim.hashValue = sim.hashValue xor uint64(value + 0x9E37)
  sim.hashValue = sim.hashValue * 0x100000001B3'u64
  sim.hashValue = sim.hashValue xor (sim.hashValue shr 29)

proc gameHash*(sim: SimServer): uint64 {.inline.} = sim.hashValue

proc mixTick(sim: SimServer) =
  ## The fixed mixing order (design note §Determinism, point 4).
  for i, train in sim.trains:
    sim.mixHash(i)
    sim.mixHash(ord(train.state))
    sim.mixHash(train.cell)
    sim.mixHash(int(train.heading))
    sim.mixHash(train.progress)
    sim.mixHash(train.malfunctionLeft)
    sim.mixHash(train.stalledTicks)
    sim.mixHash(ord(train.order.verb))
    for ch in train.order.arg:
      sim.mixHash(ord(ch))
  sim.mixHash(sim.arrivedTotal)
  sim.mixHash(sim.fleetOnTime)
  for s in 0 ..< sim.seatCount():
    sim.mixHash(sim.arrived[s])
    sim.mixHash(sim.onTime[s])
  for train in sim.activeJam:
    sim.mixHash(0x11 + train)
  for train in sim.activeDeadlock:
    sim.mixHash(0x22 + train)
  sim.mixHash(sim.tick)

# ---------------------------------------------------------------------------
#  Scoring
# ---------------------------------------------------------------------------

proc scoreFor*(sim: SimServer, seat: int): int =
  ## `1000 * fleetOnTime + 10 * arrivedTotal + onTime[s]`. Higher is better;
  ## no term is ever negative. The first two are IDENTICAL for all four seats
  ## (pure common interest); the third is an epsilon tie-break, bounded so the
  ## ordering is strictly lexicographic.
  1000 * sim.fleetOnTime + 10 * sim.arrivedTotal +
    (if seat >= 0 and seat < MaxSeats: sim.onTime[seat] else: 0)

proc networkWin*(sim: SimServer): bool {.inline.} =
  sim.fleetOnTime >= sim.config.parOnTime

# ---------------------------------------------------------------------------
#  Orders
# ---------------------------------------------------------------------------

proc seatOwns*(sim: SimServer, seat, train: int): bool {.inline.} =
  train >= 0 and train < sim.trains.len and sim.trains[train].owner == seat

proc seatTrains*(sim: SimServer, seat: int): seq[int] =
  for i, train in sim.trains:
    if train.owner == seat:
      result.add(i)

proc applyOrder*(sim: SimServer, train: int, order: TrainOrder) =
  ## Installs one accepted order. A train not named keeps the order it had.
  if train < 0 or train >= sim.trains.len:
    return
  let same = sim.trains[train].order.verb == order.verb and
    sim.trains[train].order.arg == order.arg
  sim.trains[train].order = order
  if same:
    inc sim.trains[train].orderAge
  else:
    sim.trains[train].orderAge = 1
    sim.trains[train].routeVia = order.verb == ovRoute
    sim.trains[train].route = @[]
    discard sim.map.planRoute(sim.trains[train])

# ---------------------------------------------------------------------------
#  The tick
# ---------------------------------------------------------------------------

proc trainDirectionOnEdge(sim: SimServer, cell: int, heading: Dir): int =
  ## +1 when the train runs A->B along the edge holding `cell`, -1 for B->A.
  if sim.map.edgeFwd[cell] == heading: 1 else: -1

proc opposingOnEdge(sim: SimServer, edge, direction, ignore: int): int =
  ## The lowest-id train on `edge` travelling against `direction`, or -1.
  result = -1
  for i, train in sim.trains:
    if i == ignore or not train.onGrid():
      continue
    if sim.map.edgeOf[train.cell] != edge:
      continue
    if sim.trainDirectionOnEdge(train.cell, train.heading) != direction:
      return i

proc settleEnd(sim: SimServer, rule: EndRule, reason: EndReason, detail = "") =
  if sim.phase == GameOver:
    return
  sim.phase = GameOver
  sim.endRule = rule
  sim.reason = reason
  if detail.len > 0:
    sim.stopDetail = detail.truncateRunes(MaxFallbackDetailRunes)
  sim.gameOverTicksLeft = sim.config.gameOverTicks
  for i, train in sim.trains.mpairs:
    if train.state != tsArrived and i in sim.activeDeadlock:
      train.stranded = true
      inc sim.stranded
  if sim.activeDeadlock.len > 0:
    sim.terminalDeadlock = true
  sim.emit(SimEvent(tick: sim.tick, kind: PhaseChange, content: $rule))

proc stopAtWallClock*(sim: SimServer) =
  ## The load-bearing wall-clock stop. A wall-clock fact cannot be re-derived
  ## from sim state, so it is written as ONE record and applied by THIS proc
  ## on record and on playback alike (the particle-worlds 2026-08-26 scar).
  sim.settleEnd(erWallClock, reDeadline, "wall clock budget reached")

proc faultStop*(sim: SimServer, detail: string) =
  sim.settleEnd(erFault, reFault, detail)

proc allArrived*(sim: SimServer): bool =
  for train in sim.trains:
    if train.state != tsArrived:
      return false
  true

proc step*(sim: SimServer) =
  ## One Flatland `step`. THIS IS THE WHOLE PHYSICS OF THE GAME.
  if sim.phase != Playing:
    return
  sim.frameEvents.setLen(0)
  inc sim.tick
  let cfg = sim.config
  var quiet = true

  # 2. malfunction rolls -----------------------------------------------------
  for i in 0 ..< sim.trains.len:
    if sim.trains[i].state != tsRunning and sim.trains[i].state != tsHeld:
      continue
    if sim.trains[i].malfunctionLeft > 0:
      continue
    let duration = malfunctionDraw(cfg.seed, i, sim.tick, cfg.malfunctionRate,
                                   cfg.malfunctionMinDuration,
                                   cfg.malfunctionMaxDuration)
    if duration <= 0:
      continue
    sim.trains[i].malfunctionLeft = duration
    sim.trains[i].state = tsMalfunctioning
    inc sim.malfunctions
    sim.emit(SimEvent(tick: sim.tick, kind: Malfunction, train: i,
                      slot: sim.trains[i].owner, cell: sim.trains[i].cell,
                      amount: duration))

  # 3. malfunction countdown -------------------------------------------------
  for i in 0 ..< sim.trains.len:
    if sim.trains[i].state != tsMalfunctioning:
      continue
    quiet = false
    dec sim.trains[i].malfunctionLeft
    inc sim.trains[i].malfunctionTicks
    inc sim.malfunctionTicks
    if sim.trains[i].malfunctionLeft <= 0:
      sim.trains[i].malfunctionLeft = 0
      sim.trains[i].state = tsRunning
      sim.emit(SimEvent(tick: sim.tick, kind: Repaired, train: i,
                        slot: sim.trains[i].owner, cell: sim.trains[i].cell))

  # 4. departures ------------------------------------------------------------
  for i in 0 ..< sim.trains.len:
    if sim.trains[i].state != tsWaiting:
      continue
    if sim.tick < sim.trains[i].earliestDeparture:
      continue
    if sim.trains[i].order.verb == ovHold:
      continue
    let cell = sim.trains[i].startCell
    if sim.occ.at(cell) >= 0:
      continue
    sim.trains[i].state = tsRunning
    sim.trains[i].cell = cell
    sim.trains[i].heading = sim.trains[i].startHeading
    sim.trains[i].progress = 0
    sim.occ.put(cell, i)
    discard sim.map.planRoute(sim.trains[i])
    quiet = false
    sim.emit(SimEvent(tick: sim.tick, kind: Depart, train: i,
                      slot: sim.trains[i].owner, cell: cell,
                      station: sim.map.stationOf[cell]))

  # 5. one action per running, non-malfunctioning train ----------------------
  var actions = newSeq[Action](sim.trains.len)
  for i in 0 ..< sim.trains.len:
    actions[i] = acDoNothing
    if sim.trains[i].state == tsRunning or sim.trains[i].state == tsHeld:
      actions[i] = driveTrain(sim.map, sim.trains[i])

  # 6. progress --------------------------------------------------------------
  for i in 0 ..< sim.trains.len:
    if not sim.trains[i].onGrid() or sim.trains[i].state == tsMalfunctioning:
      continue
    if actions[i] == acStop:
      sim.trains[i].state = tsHeld
      continue
    sim.trains[i].state = tsRunning
    if sim.trains[i].progress < sim.trains[i].ticksPerCell:
      inc sim.trains[i].progress

  # 7. move resolution, in ascending train id --------------------------------
  for i in 0 ..< sim.trains.len:
    sim.waitsFor[i] = -1
  var moved = newSeq[bool](sim.trains.len)
  for i in 0 ..< sim.trains.len:
    if not sim.trains[i].onGrid() or sim.trains[i].state == tsMalfunctioning:
      continue
    if actions[i] == acStop:
      continue
    if sim.trains[i].progress < sim.trains[i].ticksPerCell:
      continue
    let exit = resolveExit(sim.map, sim.trains[i], actions[i])
    if exit.repaired:
      inc sim.actionsRepaired
    let target = sim.map.step(sim.trains[i].cell, exit.dir)
    if target < 0 or not sim.map.isRail(target):
      inc sim.trains[i].blockedTicks
      continue
    # 7b. segment interlock
    let
      targetEdge = sim.map.edgeOf[target]
      ownEdge = sim.map.edgeOf[sim.trains[i].cell]
    if targetEdge >= 0 and targetEdge != ownEdge:
      let direction =
        if sim.map.edgeFwd[target] == exit.dir: 1 else: -1
      let blocker = sim.opposingOnEdge(targetEdge, direction, i)
      if blocker >= 0:
        inc sim.trains[i].blockedTicks
        sim.waitsFor[i] = blocker
        continue
    # 7c. exclusive cells
    let sitting = sim.occ.at(target)
    if sitting >= 0:
      inc sim.trains[i].blockedTicks
      sim.waitsFor[i] = sitting
      continue
    sim.occ.free(sim.trains[i].cell)
    sim.trains[i].cell = target
    sim.trains[i].heading = if exit.reversed: opposite(sim.trains[i].heading)
                            else: exit.dir
    sim.trains[i].progress = 0
    sim.occ.put(target, i)
    moved[i] = true
    quiet = false
    if sim.trains[i].route.len > 0 and sim.trains[i].route[0] == target:
      sim.trains[i].route.delete(0)

  # 8. arrivals --------------------------------------------------------------
  for i in 0 ..< sim.trains.len:
    if not sim.trains[i].onGrid():
      continue
    if sim.map.stationOf[sim.trains[i].cell] != sim.trains[i].target:
      continue
    sim.occ.free(sim.trains[i].cell)
    sim.trains[i].state = tsArrived
    sim.trains[i].arrivalTick = sim.tick
    sim.trains[i].lateness = max(0, sim.tick - sim.trains[i].scheduledArrival)
    sim.trains[i].onTime = sim.tick <= sim.trains[i].scheduledArrival
    sim.trains[i].lastResult = orArrived
    sim.trains[i].cell = -1
    sim.trains[i].route = @[]
    inc sim.arrivedTotal
    inc sim.arrived[sim.trains[i].owner]
    sim.latenessTicks[sim.trains[i].owner] += sim.trains[i].lateness
    if sim.trains[i].onTime:
      inc sim.fleetOnTime
      inc sim.onTime[sim.trains[i].owner]
    quiet = false
    sim.emit(SimEvent(tick: sim.tick, kind: Arrive, train: i,
                      slot: sim.trains[i].owner, station: sim.trains[i].target,
                      amount: sim.trains[i].lateness,
                      cell: (if sim.trains[i].onTime: 1 else: 0)))

  # 9. stall accounting ------------------------------------------------------
  for i in 0 ..< sim.trains.len:
    if not sim.trains[i].onGrid() or sim.trains[i].state == tsMalfunctioning or
        actions[i] == acStop or moved[i] or
        sim.trains[i].progress < sim.trains[i].ticksPerCell:
      sim.trains[i].stalledTicks = 0
    else:
      inc sim.trains[i].stalledTicks
      if sim.trains[i].stalledTicks == 1:
        sim.emit(SimEvent(tick: sim.tick, kind: Blocked, train: i,
                          slot: sim.trains[i].owner, cell: sim.trains[i].cell))

  # 10. jam and deadlock detection -------------------------------------------
  let report = analyse(sim.trains, sim.waitsFor, cfg.jamTicks, cfg.deadlockTicks)
  if report.jam != sim.activeJam:
    if sim.activeJam.len == 0 and report.jam.len > 0:
      inc sim.jams
      sim.jamStartTick = sim.tick
      sim.emit(SimEvent(tick: sim.tick, kind: Jam, trains: report.jam))
    elif report.jam.len == 0 and sim.activeJam.len > 0:
      sim.emit(SimEvent(tick: sim.tick, kind: JamClear, trains: sim.activeJam,
                        amount: sim.currentJamRun))
      sim.currentJamRun = 0
      sim.jamStartTick = -1
  if report.jam.len > 0:
    inc sim.jamTicks
    inc sim.currentJamRun
    sim.longestJamTicks = max(sim.longestJamTicks, sim.currentJamRun)
  sim.activeJam = report.jam

  if report.deadlock != sim.activeDeadlock:
    if sim.activeDeadlock.len == 0 and report.deadlock.len > 0:
      inc sim.deadlocks
      sim.deadlockStartTick = sim.tick
      sim.emit(SimEvent(tick: sim.tick, kind: Deadlock, trains: report.deadlock))
    elif report.deadlock.len == 0 and sim.activeDeadlock.len > 0:
      sim.emit(SimEvent(tick: sim.tick, kind: DeadlockClear,
                        trains: sim.activeDeadlock,
                        amount: max(0, sim.tick - sim.deadlockStartTick)))
      sim.deadlockStartTick = -1
  if report.deadlock.len > 0:
    inc sim.deadlockTicks
  sim.activeDeadlock = report.deadlock
  sim.deadlockCells = report.deadlockCells
  for train in sim.activeDeadlock:
    sim.trains[train].lastResult = orDeadlocked

  # 11. the hash chain -------------------------------------------------------
  sim.mixTick()
  sim.hashes.add(sim.hashValue)

  # 12. end conditions -------------------------------------------------------
  if quiet and sim.activeDeadlock.len == 0 and sim.arrivedTotal < sim.trains.len:
    inc sim.quietTicks
  elif quiet:
    inc sim.quietTicks
  else:
    sim.quietTicks = 0
  if sim.allArrived():
    sim.settleEnd(erAllArrived, reComplete)
  elif sim.quietTicks >= cfg.quiesceTicks:
    sim.settleEnd(erQuiescent, reComplete)
  elif sim.tick >= cfg.maxTicks:
    sim.settleEnd(erTickCap, reComplete)

proc startPlaying*(sim: SimServer) =
  if sim.phase == Lobby:
    sim.phase = Playing
    sim.emit(SimEvent(tick: sim.tick, kind: PhaseChange, content: "playing"))

# ---------------------------------------------------------------------------
#  The per-seat observation
# ---------------------------------------------------------------------------

proc routeLabels*(sim: SimServer, train: Train, limit: int): seq[string] =
  ## The next labelled points along the cached route: station letters, siding
  ## ids and named junctions, nearest first.
  var seen: seq[string]
  for cell in train.route:
    let edge = sim.map.edgeOf[cell]
    if edge >= 0 and sim.map.edges[edge].siding >= 0:
      let id = SidingIds[sim.map.edges[edge].siding]
      if id notin seen:
        seen.add(id)
    let label = sim.map.nodeIdOf(cell)
    if label.len > 0 and label notin seen:
      seen.add(label)
    if seen.len >= limit:
      break
  if seen.len < limit:
    let target = $StationLetters[train.target]
    if target notin seen:
      seen.add(target)
  seen

proc nextDecision*(sim: SimServer, train: Train): tuple[node: string, eta: int] =
  ## The next node with more than one legal exit, and the ETA in ticks.
  ## This is how "decisions only matter at switches" reaches the seat without
  ## making the engine's schedule data-dependent.
  var cells = 0
  for cell in train.route:
    inc cells
    if not sim.map.isNode[cell]:
      continue
    var exits = 0
    for d in 0 .. 3:
      if sim.map.hasEnd(cell, Dir(d)):
        inc exits
    if exits > 2:
      let label = sim.map.nodeIdOf(cell)
      return ((if label.len > 0: label else: "@" & $cell),
              cells * train.ticksPerCell)
  ("", 0)

proc trainStateName(train: Train): string = $train.state

proc seatObservation*(sim: SimServer, seat, turnIndex, turns: int): JsonNode =
  ## Everything this seat may legitimately know. Infrastructure and block
  ## occupancy are PUBLIC; intentions are PRIVATE. No other seat's targets,
  ## routes, orders, notes, real name or policy kind is in here, and nothing
  ## about any seat's identity ever reaches a prompt.
  var stations = newJArray()
  for ch in StationLetters:
    stations.add(%($ch))
  var sidings = newJArray()
  for id in SidingIds:
    sidings.add(%id)
  var junctions = newJArray()
  for id in JunctionIds:
    junctions.add(%id)
  var dispatchers = newJArray()
  for s in 0 ..< sim.seatCount():
    dispatchers.add(%seatAlias(s))

  var yours = newJArray()
  for i in sim.seatTrains(seat):
    let train = sim.trains[i]
    var entry = %*{
      "id": trainId(i),
      "state": trainStateName(train),
      "cell": (if train.cell >= 0:
                 %[sim.map.cellX(train.cell), sim.map.cellY(train.cell)]
               else: newJNull()),
      "heading": dirName(train.heading),
      "ticks_per_cell": train.ticksPerCell,
      "target": $StationLetters[train.target],
      "scheduled_arrival": train.scheduledArrival,
      "ticks_late": (if train.state == tsArrived: train.lateness
                     else: max(0, sim.tick - train.scheduledArrival)),
      "order": $train.order.verb,
      "order_age_turns": train.orderAge,
      "last_order_result": $train.lastResult,
      "blocked_ticks_last_turn": train.blockedLastTurn,
      "malfunction_left": train.malfunctionLeft
    }
    if train.state == tsWaiting:
      entry["earliest_departure"] = %train.earliestDeparture
    if train.order.arg.len > 0:
      entry["order_arg"] = %train.order.arg
    var routeNext = newJArray()
    for label in sim.routeLabels(train, 3):
      routeNext.add(%label)
    entry["route_next"] = routeNext
    let decision = sim.nextDecision(train)
    entry["next_decision"] =
      if decision.node.len > 0:
        %*{"node": decision.node, "eta_ticks": decision.eta}
      else:
        newJNull()
    yours.add(entry)

  var occupancy = newJArray()
  for i, train in sim.trains:
    if not train.onGrid():
      continue
    var entry = %*{
      "id": trainId(i),
      "by": seatAlias(train.owner),
      "cell": [sim.map.cellX(train.cell), sim.map.cellY(train.cell)],
      "heading": dirName(train.heading),
      "ticks_per_cell": train.ticksPerCell,
      "state": trainStateName(train)
    }
    if train.stalledTicks > 0:
      entry["stalled"] = %train.stalledTicks
    occupancy.add(entry)

  var radio = newJArray()
  for s in 0 ..< sim.seatCount():
    if s == seat or sim.seats[s].radio.len == 0:
      continue
    radio.add(%*{"from": seatAlias(s), "text": sim.seats[s].radio})
    if radio.len >= 3:
      break

  var jam = newJArray()
  for train in sim.activeJam:
    jam.add(%trainId(train))
  var deadlockList = newJArray()
  for train in sim.activeDeadlock:
    deadlockList.add(%trainId(train))
  var deadlockCells = newJArray()
  for cell in sim.deadlockCells:
    deadlockCells.add(%[sim.map.cellX(cell), sim.map.cellY(cell)])

  result = %*{
    "you": seatAlias(seat),
    "dispatchers": dispatchers,
    "turn": turnIndex,
    "of": turns,
    "tick": sim.tick,
    "turn_ticks": sim.config.turnTicks,
    "ticks_left": max(0, sim.config.maxTicks - sim.tick),
    "network": {
      "name": sim.network,
      "width": sim.map.width,
      "height": sim.map.height,
      "stations": stations,
      "sidings": sidings,
      "junctions": junctions
    },
    "your_trains": yours,
    "block_occupancy": occupancy,
    "radio": radio,
    "network_status": {
      "arrived": sim.arrivedTotal,
      "on_time": sim.fleetOnTime,
      "malfunctions": sim.malfunctions,
      "jam": jam,
      "deadlock": deadlockList,
      "deadlock_cells": deadlockCells
    }
  }

proc junctionGraphJson*(sim: SimServer): JsonNode =
  ## The static junction graph, published ONCE at registration: for each edge
  ## its two endpoint node ids, its length in cells, and whether a parallel
  ## edge exists between the same pair.
  result = newJArray()
  for edge in sim.map.edges:
    let
      a = sim.map.nodeIdOf(edge.nodeA)
      b = sim.map.nodeIdOf(edge.nodeB)
    if a.len == 0 or b.len == 0:
      continue
    result.add(%*{
      "a": a, "b": b, "cells": edge.cells.len + 1,
      "both_ways": edge.parallel,
      "siding": (if edge.siding >= 0: %SidingIds[edge.siding] else: newJNull())
    })

proc railAsciiJson*(sim: SimServer): JsonNode =
  ## The rail map as the same ASCII tile grid the file carries.
  result = newJArray()
  for y in 0 ..< sim.map.height:
    var row = newStringOfCap(sim.map.width)
    for x in 0 ..< sim.map.width:
      row.add(sim.map.tiles[y * sim.map.width + x])
    result.add(%row)
