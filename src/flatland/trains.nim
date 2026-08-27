## The trains: the per-train record, the seeded reset draw, and the
## occupancy layer the tick loop reads and writes through.
##
## Pure integer arithmetic — speed is an integer `ticksPerCell`
## (1 = express, 2 = fast, 3 = local, 4 = freight), which is exactly
## upstream's fractional-position accumulator for reciprocal speeds without
## the float (divergence 3), and is what makes the native <-> wasm hash chain
## exact by construction.

import sim_types, sim_config, railmap, upstream

type
  Train* = object
    owner*: int                 ## seat slot 0..3
    startCell*: int
    startHeading*: Dir
    target*: int                ## station index 0..7
    ticksPerCell*: int
    earliestDeparture*: int
    scheduledArrival*: int
    plannedCells*: int
    state*: TrainState
    cell*: int                  ## -1 while waiting or after arrival
    heading*: Dir
    progress*: int
    malfunctionLeft*: int
    malfunctionTicks*: int
    stalledTicks*: int
    blockedTicks*: int
    blockedAtTurn*: int         ## `blockedTicks` at the last turn boundary
    blockedLastTurn*: int       ## refusals SINCE that boundary, not the total
    arrivalTick*: int
    lateness*: int
    onTime*: bool
    stranded*: bool
    order*: TrainOrder
    orderAge*: int
    lastResult*: OrderResult
    route*: seq[int]            ## remaining cell path, nearest hop first
    routeGoal*: seq[int]        ## the goal cells the route was planned to
    routeVia*: bool             ## the `route via V` first leg is still live

  Occupancy* = object
    ## cell -> train index, or -1. The tick loop snapshots this once and
    ## writes through it as trains commit, in train-id order.
    byCell*: seq[int]

proc initOccupancy*(map: RailMap): Occupancy =
  result.byCell = newSeq[int](map.tiles.len)
  for i in 0 ..< result.byCell.len:
    result.byCell[i] = -1

proc clear*(occ: var Occupancy) =
  for i in 0 ..< occ.byCell.len:
    occ.byCell[i] = -1

proc at*(occ: Occupancy, cell: int): int {.inline.} =
  if cell < 0 or cell >= occ.byCell.len: -1 else: occ.byCell[cell]

proc put*(occ: var Occupancy, cell, train: int) {.inline.} =
  if cell >= 0 and cell < occ.byCell.len:
    occ.byCell[cell] = train

proc free*(occ: var Occupancy, cell: int) {.inline.} =
  if cell >= 0 and cell < occ.byCell.len:
    occ.byCell[cell] = -1

proc onGrid*(train: Train): bool {.inline.} =
  train.state in {tsRunning, tsHeld, tsMalfunctioning} and train.cell >= 0

proc speedMultiset*(trainCount: int): seq[int] =
  ## A FIXED multiset — for 24 trains exactly six of each of the four speed
  ## classes, for 16 trains exactly four each — so the composition never
  ## varies between episodes, only the assignment.
  let per = trainCount div SpeedClasses.len
  for speed in SpeedClasses:
    for _ in 0 ..< per:
      result.add(speed)

proc setupTrains*(map: RailMap, config: GameConfig): seq[Train] =
  ## The reset draw, consumed from one splitmix64 stream in this fixed order:
  ##   (b) the injection of trains onto start platform cells;
  ##   (c) each train's target station;
  ##   (d) the speed classes;
  ##   (e) the departure order.
  ## (a), the network, is `pool[seed mod 3]` and is drawn by the caller before
  ## this runs. NOTHING here depends on anything a policy does.
  let count = config.trainCount()
  var rng = initRng(config.seed)

  # (b) start platforms
  var platforms: seq[int]
  for station in 0 ..< map.stationCells.len:
    for cell in map.stationCells[station]:
      platforms.add(cell)
  rng.shuffle(platforms)
  if platforms.len < count:
    raise newException(FlatlandError, "not enough platform cells for " & $count & " trains")

  result = newSeq[Train](count)
  for i in 0 ..< count:
    result[i].owner = i div config.trainsPerSeat
    result[i].startCell = platforms[i]
    result[i].startHeading = map.platformOutboundHeading(platforms[i])
    result[i].state = tsWaiting
    result[i].cell = -1
    result[i].heading = result[i].startHeading
    result[i].order = TrainOrder(verb: ovRun, arg: "")
    result[i].lastResult = orHeld

  # (c) targets: uniform over the seven stations that are not the start,
  # re-drawn until the journey is long enough, bounded at 200 attempts.
  for i in 0 ..< count:
    let startStation = map.stationOf[result[i].startCell]
    var
      best = -1
      bestCells = -1
      chosen = -1
      cells = -1
    for attempt in 0 ..< 200:
      var candidate = rng.rand(map.stationCells.len - 1)
      if candidate >= startStation:
        inc candidate
      let d = map.routeCells(result[i].startCell, result[i].startHeading,
                             map.stationCells[candidate])
      if d > bestCells:
        bestCells = d
        best = candidate
      if d >= config.minJourneyCells:
        chosen = candidate
        cells = d
        break
    if chosen < 0:
      chosen = best
      cells = bestCells
    if chosen < 0 or cells < 0:
      raise newException(FlatlandError, "no reachable target for train " & $i)
    result[i].target = chosen
    result[i].plannedCells = cells

  # (d) speed classes
  var speeds = speedMultiset(count)
  rng.shuffle(speeds)
  for i in 0 ..< count:
    result[i].ticksPerCell = speeds[i]

  # (e) departure order
  var order = newSeq[int](count)
  for i in 0 ..< count:
    order[i] = i
  rng.shuffle(order)
  for rank, train in order:
    result[train].earliestDeparture = config.departStagger * rank

  for i in 0 ..< count:
    result[i].scheduledArrival = result[i].earliestDeparture +
      result[i].ticksPerCell * result[i].plannedCells + config.slackTicks

proc malfunctionDraw*(seed: uint64, train, tick, rate, minDuration,
                      maxDuration: int): int =
  ## Whether train `train` breaks at tick `tick`, and for how long. A PURE
  ## HASH of `(seed, trainId, tick)`, not a consumed stream: nothing a
  ## dispatcher does can shift another train's draws, change their order or
  ## consume them out from under it (the idea's "malfunctions seeded").
  ## Returns 0 for "no breakdown".
  let h = mix64(seed, train, tick)
  if rate <= 0 or (h mod uint64(rate)) != 0:
    return 0
  let span = maxDuration - minDuration + 1
  minDuration + int((h shr 32) mod uint64(max(1, span)))
