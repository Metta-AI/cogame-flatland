## The two scripted baselines. Both emit the SAME order objects an LLM does,
## through the same validator, which is what makes the bounded-orders test
## meaningful. Neither ever emits `say` or `notes` — they are the dispatchers
## who will not talk to you, which is precisely the "yielding conventions
## without a central scheduler" problem the game is about.
##
## `yielder` is ALSO the server-side fallback: `decide.nim` imports THIS proc
## rather than duplicating it, so the two can never drift
## (`tests/test_flatland_driver.nim` asserts they are the same proc).

import std/strutils

import sim_types, sim_config, railmap, trains, driver, directives

type
  Baseline* = enum
    blTimetable = "timetable"
    blYielder = "yielder"

  BaselineParams* = object
    ## The four tunables, chosen by `tools/tune_baselines.nim`'s head-to-head
    ## sweep and recorded in `tools/ci/baseline_tuning.json`, not guessed.
    yieldAfter*: int
    departLookahead*: int
    sidingLookahead*: int
    lowerIdYields*: bool

const
  DefaultBaselineParams* = BaselineParams(
    yieldAfter: 4,
    departLookahead: 1,
    sidingLookahead: 2,
    lowerIdYields: false
  )

proc parseBaseline*(text: string): Baseline =
  ## Anything unrecognised is the published default (the starter's rule).
  let key = text.strip().toLowerAscii()
  for baseline in Baseline:
    if $baseline == key:
      return baseline
  blYielder

type
  BaselineWorld* = object
    ## Everything a baseline may read. Deliberately the PUBLIC view plus this
    ## seat's own trains — the same information the observation carries.
    map*: RailMap
    trains*: seq[Train]
    occ*: Occupancy
    waitsFor*: seq[int]
    tick*: int
    params*: BaselineParams

proc nodesAhead(world: BaselineWorld, train: Train, count: int): seq[int] =
  var seen = 0
  for cell in train.route:
    if not world.map.isNode[cell]:
      continue
    result.add(cell)
    inc seen
    if seen >= count:
      break

proc trainsNear(world: BaselineWorld, cells: openArray[int]): int =
  for cell in cells:
    if world.occ.at(cell) >= 0:
      inc result

proc sidingAhead(world: BaselineWorld, train: Train, limit: int): string =
  ## The nearest siding on the route ahead, by route order, within `limit`
  ## nodes. "" when there is none.
  var nodes = 0
  for cell in train.route:
    let edge = world.map.edgeOf[cell]
    if edge >= 0 and world.map.edges[edge].siding >= 0:
      return SidingIds[world.map.edges[edge].siding]
    if world.map.isNode[cell]:
      inc nodes
      if nodes >= limit:
        break
  ""

proc nextSingleTrackConflict(world: BaselineWorld, index: int,
                             train: Train): bool =
  ## True when the next single-track section on this train's route (an edge
  ## with no parallel partner) already holds a train travelling the other way.
  var edgeSeen = -1
  for cell in train.route:
    let edge = world.map.edgeOf[cell]
    if edge < 0 or world.map.edges[edge].parallel:
      continue
    if edgeSeen >= 0 and edge != edgeSeen:
      break
    edgeSeen = edge
    for other, t in world.trains:
      if other == index or not t.onGrid():
        continue
      if world.map.edgeOf[t.cell] != edge:
        continue
      if world.map.edgeFwd[t.cell] != world.map.edgeFwd[cell]:
        return true
    break
  false

proc blockerOf(world: BaselineWorld, index: int): int =
  if index < world.waitsFor.len: world.waitsFor[index] else: -1

proc scriptedDirective*(world: BaselineWorld, kind: Baseline,
                        ctx: OrderContext): Directive =
  ## One turn of scripted dispatching. Never emits `say` or `notes`, never
  ## more than `trainsPerSeat` orders, and every order is legal by
  ## construction — the validator is applied by the caller anyway.
  result = defaultDirective(ctx)
  result.source = dsScripted
  for slot in 0 ..< ctx.trainIndex.len:
    let index = ctx.trainIndex[slot]
    let train = world.trains[index]
    if train.state == tsArrived:
      continue
    var verb = ovRun
    var arg = ""
    case kind
    of blTimetable:
      ## Pure greed, no yielding: release as early as possible and run.
      verb = ovRun
    of blYielder:
      block decide:
        if train.state == tsWaiting:
          let ahead = nodesAhead(world, train, world.params.departLookahead)
          if trainsNear(world, ahead) >= 2:
            verb = ovHold
          else:
            verb = ovRun
          break decide
        let blocker = blockerOf(world, index)
        if train.stalledTicks >= world.params.yieldAfter and blocker >= 0 and
            ((blocker < index) == world.params.lowerIdYields):
          let siding = sidingAhead(world, train, world.params.sidingLookahead)
          if siding.len > 0:
            verb = ovSiding
            arg = siding
          else:
            verb = ovHold
          break decide
        if nextSingleTrackConflict(world, index, train):
          let siding = sidingAhead(world, train, world.params.sidingLookahead)
          if siding.len > 0:
            verb = ovSiding
            arg = siding
          else:
            verb = ovHold
          break decide
        if train.order.verb == ovSiding and
            not nextSingleTrackConflict(world, index, train):
          verb = ovRun
          break decide
        verb = ovRun
    result.orders[slot] = OrderEntry(train: index, verb: verb, arg: arg,
                                     fromReply: true)

proc yielderDirective*(world: BaselineWorld, ctx: OrderContext): Directive =
  ## THE fallback. `decide.nim` calls this proc; it is not a copy of the
  ## yielder rules, it IS the yielder baseline.
  scriptedDirective(world, blYielder, ctx)

const scriptedDirectiveYielderAlias* = yielderDirective
  ## `tests/test_flatland_driver.nim` compares the engine's fallback against
  ## this, so a second copy of the yielder rules cannot be introduced without
  ## the test noticing.
