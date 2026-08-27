## The driver: the deterministic layer between a dispatcher's ORDER and the
## per-tick five-action space. Forked from `coworld-ctf`'s `control.nim`
## (directive -> per-tick actuation), retargeted from pixel steering to
## Flatland's discrete actions.
##
## It runs once per train per tick and is the ONLY producer of actions. There
## is no randomness in it at all, and no floating point.

import sim_types, railmap, trains

proc goalCellsFor*(map: RailMap, train: Train): seq[int] =
  ## The cells this train's current order is steering it to.
  case train.order.verb
  of ovHold:
    @[]
  of ovRun:
    map.stationCells[train.target]
  of ovSiding:
    map.goalCellsFor(train.order.arg)
  of ovRoute:
    if train.routeVia:
      map.goalCellsFor(train.order.arg)
    else:
      map.stationCells[train.target]

proc onSiding*(map: RailMap, train: Train, sidingId: string): bool =
  let siding = sidingIndex(sidingId)
  if siding < 0 or train.cell < 0:
    return false
  for cell in map.sidingCells(siding):
    if cell == train.cell:
      return true
  false

proc planRoute*(map: RailMap, train: var Train): bool =
  ## Recomputes the cached route. Other trains are NOT obstacles in the plan
  ## (they move); the interlock and the occupancy check are enforced at commit
  ## time, in the tick loop.
  train.route = @[]
  ## A WAITING train plans from its start platform, so the observation can
  ## show it a `route_next` and the `yielder` baseline can look ahead before
  ## releasing it.
  let fromCell = if train.cell >= 0: train.cell else: train.startCell
  let fromHeading = if train.cell >= 0: train.heading else: train.startHeading
  if fromCell < 0:
    return false
  var goals = map.goalCellsFor(train)
  if goals.len == 0:
    train.routeGoal = @[]
    return false
  train.routeGoal = goals
  train.route = map.bfsRoute(fromCell, fromHeading, goals)
  train.route.len > 0

proc atGoal*(train: Train): bool {.inline.} =
  if train.cell < 0:
    return false
  for cell in train.routeGoal:
    if cell == train.cell:
      return true
  false

proc actionToward*(map: RailMap, train: Train, nextCell: int): Action =
  ## The action whose exit end reaches `nextCell`. Emitted even if a train is
  ## standing there — the leader may move first this tick and refusing to try
  ## would forfeit the advance.
  for d in 0 .. 3:
    if map.step(train.cell, Dir(d)) != nextCell:
      continue
    if Dir(d) == train.heading:
      return acMoveForward
    if Dir(d) == leftOf(train.heading):
      return acMoveLeft
    if Dir(d) == rightOf(train.heading):
      return acMoveRight
    return acMoveForward   ## a dead-end reversal: forward turns the train 180
  acMoveForward

proc driveTrain*(map: RailMap, train: var Train): Action =
  ## One tick of actuation for one train. Never leaves a running train
  ## without an action.
  if train.state == tsMalfunctioning:
    return acDoNothing
  if train.state != tsRunning and train.state != tsHeld:
    return acDoNothing
  if train.order.verb == ovHold:
    return acStop
  if train.order.verb == ovSiding and map.onSiding(train, train.order.arg):
    return acStop
  # The tick loop increments `progress` AFTER the driver runs (step 6 follows
  # step 5) and moves the trains whose progress then EQUALS ticksPerCell, so
  # the driver must decide against the progress this train is about to have.
  # Testing the pre-increment value made every train emit DoNothing on exactly
  # the tick it moved, i.e. drive permanently straight ahead.
  if train.progress + 1 < train.ticksPerCell:
    return acDoNothing
  if train.order.verb == ovRoute and train.routeVia and train.atGoal():
    ## the via point is reached: continue automatically to the target.
    train.routeVia = false
    discard map.planRoute(train)
  if train.route.len == 0:
    if not map.planRoute(train):
      train.lastResult =
        if train.order.verb == ovSiding: orNoSiding else: orNoRoute
      return acStop
  # Drop hops we are already standing on (a seek or a repair can leave one).
  while train.route.len > 0 and train.route[0] == train.cell:
    train.route.delete(0)
  if train.route.len == 0:
    return acStop
  let nextCell = train.route[0]
  var reachable = false
  for d in map.exitsFrom(train.cell, train.heading):
    if map.step(train.cell, d) == nextCell:
      reachable = true
      break
  if not reachable:
    if not map.planRoute(train):
      train.lastResult =
        if train.order.verb == ovSiding: orNoSiding else: orNoRoute
      return acStop
    while train.route.len > 0 and train.route[0] == train.cell:
      train.route.delete(0)
    if train.route.len == 0:
      return acStop
  map.actionToward(train, train.route[0])

proc resolveExit*(map: RailMap, train: Train, action: Action):
    tuple[dir: Dir, repaired: bool, reversed: bool] =
  ## Tick step 7a. Turns an action into the exit end it takes, repairing an
  ## illegal one in the documented fixed order: `MoveForward` if legal, else
  ## the single legal exit if there is exactly one, else the legal exit with
  ## the lowest direction index.
  let wanted =
    case action
    of acMoveLeft: leftOf(train.heading)
    of acMoveRight: rightOf(train.heading)
    else: train.heading
  let outs = map.exitsFrom(train.cell, train.heading)
  if outs.len == 0:
    ## a dead end with no exits at all cannot happen (exitsFrom reverses),
    ## but keep the train moving rather than stalling it forever.
    return (opposite(train.heading), true, true)
  if map.isDeadEnd(train.cell):
    return (opposite(train.heading), false, true)
  for d in outs:
    if d == wanted:
      return (d, false, false)
  for d in outs:
    if d == train.heading:
      return (d, true, false)
  if outs.len == 1:
    return (outs[0], true, false)
  (outs[0], true, false)
