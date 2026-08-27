## Head-to-head sweep for the `yielder` baseline's four tunables.
##
## Forked from `coworld-ctf`'s `tools/tune_baselines.nim`. The shipped
## `DefaultBaselineParams` are the sweep's PICK, not a guess:
## `tools/ci/baseline_tuning.json` records it and
## `tests/test_flatland_tuning.nim` asserts the two still agree.
##
##   nim c -r --path:src tools/tune_baselines.nim            # sweep and print
##   nim c -r --path:src tools/tune_baselines.nim --write    # rewrite the JSON
##   nim c -r --path:src tools/tune_baselines.nim --check    # CI: re-run and compare

import std/[json, os, strformat, strutils]

import flatland/[sim, directives, baselines]

const TuningPath = "tools/ci/baseline_tuning.json"

proc contextFor(game: SimServer, seat: int): OrderContext =
  result.map = game.map
  result.cap = game.config.trainsPerSeat
  for i in game.seatTrains(seat):
    result.trainIds.add(trainId(i))
    result.trainIndex.add(i)
    result.arrived.add(game.trains[i].state == tsArrived)
    result.previous.add(game.trains[i].order)

proc play(seed: uint64, pool: string, trainsPerSeat: int,
          kinds: array[4, Baseline], params: BaselineParams):
    tuple[onTime, arrived, deadlocks: int] =
  var config = defaultGameConfig()
  config.seed = seed
  config.networkPool = pool
  config.trainsPerSeat = trainsPerSeat
  config.parOnTime = if pool == "mainline": 15 else: 9
  let game = newSimServer(config)
  game.startPlaying()
  while game.phase == Playing:
    if game.tick mod config.turnTicks == 0:
      let world = BaselineWorld(map: game.map, trains: game.trains, occ: game.occ,
                                waitsFor: game.waitsFor, tick: game.tick,
                                params: params)
      for seat in 0 ..< 4:
        let directive = scriptedDirective(world, kinds[seat], game.contextFor(seat))
        for order in directive.orders:
          game.applyOrder(order.train, TrainOrder(verb: order.verb, arg: order.arg))
    game.step()
  (game.fleetOnTime, game.arrivedTotal, game.deadlocks)

proc score(params: BaselineParams): tuple[onTime, deadlocks: int] =
  ## The sweep's objective: on-time trains across a fixed seed set, with
  ## deadlocks as the tie-break (fewer is better). Every candidate is played
  ## HEAD TO HEAD against `timetable`, which is the cross-play the league runs.
  const Seeds = [1'u64, 2, 3, 4, 5, 6, 7, 8]
  for seed in Seeds:
    let all = play(seed, "mainline", 6,
                   [blYielder, blYielder, blYielder, blYielder], params)
    let mixed = play(seed, "mainline", 6,
                     [blYielder, blTimetable, blYielder, blTimetable], params)
    let branch = play(seed, "branchline", 4,
                      [blYielder, blYielder, blYielder, blYielder], params)
    result.onTime += all.onTime + mixed.onTime + branch.onTime
    result.deadlocks += all.deadlocks + mixed.deadlocks + branch.deadlocks

proc asJson(params: BaselineParams, best: tuple[onTime, deadlocks: int]): JsonNode =
  %*{
    "baseline": "yielder",
    "yieldAfter": params.yieldAfter,
    "departLookahead": params.departLookahead,
    "sidingLookahead": params.sidingLookahead,
    "lowerIdYields": params.lowerIdYields,
    "sweep": {"onTime": best.onTime, "deadlocks": best.deadlocks}
  }

when isMainModule:
  var
    best = DefaultBaselineParams
    bestScore = (onTime: -1, deadlocks: 0)
  for yieldAfter in [4, 6, 8, 12, 16]:
    for departLookahead in [1, 2, 3]:
      for sidingLookahead in [2, 3, 4]:
        for lowerIdYields in [true, false]:
          let params = BaselineParams(
            yieldAfter: yieldAfter, departLookahead: departLookahead,
            sidingLookahead: sidingLookahead, lowerIdYields: lowerIdYields)
          let got = score(params)
          if got.onTime > bestScore.onTime or
              (got.onTime == bestScore.onTime and
               got.deadlocks < bestScore.deadlocks):
            bestScore = got
            best = params
  let node = asJson(best, bestScore)
  echo &"best: yieldAfter={best.yieldAfter} departLookahead={best.departLookahead} " &
    &"sidingLookahead={best.sidingLookahead} lowerIdYields={best.lowerIdYields} " &
    &"onTime={bestScore.onTime} deadlocks={bestScore.deadlocks}"
  if paramCount() >= 1 and paramStr(1) == "--write":
    writeFile(TuningPath, node.pretty() & "\n")
    echo "wrote ", TuningPath
  elif paramCount() >= 1 and paramStr(1) == "--check":
    let onDisk = parseJson(readFile(TuningPath))
    for key in ["yieldAfter", "departLookahead", "sidingLookahead", "lowerIdYields"]:
      if onDisk{key} != node{key}:
        quit("baseline tuning drifted on " & key & ": committed " &
          $onDisk{key} & ", swept " & $node{key}, 1)
    echo "baseline tuning matches ", TuningPath
