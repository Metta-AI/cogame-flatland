## Numeric baseline choices over the native rail simulator.

import std/[hashes, json, os]
import flatland/[sim, decide, baselines, directives, llm, roster]

var
  game: SimServer
  seat: int
  decisionId: int
  choices: array[4, int]
  manifestPath: string
  variant: string

proc currentDecision(): JsonNode =
  let turnIndex = game.tick div game.config.turnTicks + 1
  game.turn = turnIndex
  let view = game.seatObservation(seat, turnIndex,
    game.config.turnsPerEpisode())
  let user = userMessage($game.networkBriefing(), "", $view)
  %*{"kind": "decision", "game": "flatland",
    "decision_id": decisionId, "seat": seat, "engine_seat": seat,
    "turn": turnIndex,
    "semantic_view": {"system": SystemPrompt, "user": user},
    "inbox": [], "messages": [
      {"role": "system", "content": SystemPrompt},
      {"role": "user", "content": user}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": {
      "choice": {"type": "integer", "minimum": 0, "maximum": 1}},
      "required": ["choice"]}, "typed_question": newJNull()}

proc reset(command: JsonNode): JsonNode =
  doAssert command["players"].getInt() == 4
  let manifest = parseFile(manifestPath)
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  var config = defaultGameConfig()
  config.update(variantConfig)
  config.seed = uint64(hash(command["seed"].getStr()) and 0x7FFFFFFF)
  game = newSimServer(config)
  game.startPlaying()
  seat = 0
  decisionId = 0
  choices = [0, 0, 0, 0]
  currentDecision()

proc encode(): JsonNode =
  var values = newJArray()
  for entry in RailFiles:
    values.add(%(if game.network == entry.name: 1 else: 0))
  for other in 0 ..< 4:
    values.add(%(if seat == other: 1 else: 0))
  values.add(%(float(game.tick) / float(game.config.maxTicks)))
  values.add(%(float(game.arrivedTotal) / float(game.trainCount())))
  values.add(%(float(game.fleetOnTime) / float(game.trainCount())))
  values.add(%(float(game.malfunctions) / float(game.trainCount())))
  values.add(%(float(game.activeJam.len) / float(game.trainCount())))
  values.add(%(float(game.activeDeadlock.len) / float(game.trainCount())))
  for other in 0 ..< 4:
    var count = 0
    for train in game.trains:
      if train.owner == other and train.onGrid(): inc count
    values.add(%(float(count) / float(game.config.trainsPerSeat)))
  let owned = game.seatTrains(seat)
  for slot in 0 ..< 6:
    let present = slot < owned.len
    let train = if present: game.trains[owned[slot]] else: Train()
    for state in TrainState:
      values.add(%(if present and train.state == state: 1 else: 0))
    let onGrid = present and train.onGrid()
    values.add(%(if onGrid: float(game.map.cellX(train.cell)) /
      float(game.map.width) else: -1.0))
    values.add(%(if onGrid: float(game.map.cellY(train.cell)) /
      float(game.map.height) else: -1.0))
    for direction in 0 .. 3:
      values.add(%(if onGrid and int(train.heading) == direction: 1 else: 0))
    for target in 0 ..< 8:
      values.add(%(if present and train.target == target: 1 else: 0))
    values.add(%(if present: float(train.scheduledArrival) /
      float(game.config.maxTicks) else: 0.0))
    values.add(%(if present: float(train.lateness) /
      float(game.config.maxTicks) else: 0.0))
    for verb in OrderVerb:
      values.add(%(if present and train.order.verb == verb: 1 else: 0))
    values.add(%(if present: float(train.orderAge) / 31.0 else: 0.0))
    values.add(%(if present: float(train.blockedLastTurn) /
      float(game.config.turnTicks) else: 0.0))
    values.add(%(if present: float(train.malfunctionLeft) / 24.0 else: 0.0))
    values.add(%(if present: float(train.earliestDeparture) /
      float(game.config.maxTicks) else: 0.0))
  doAssert values.len == 194
  %*{"decision_id": decisionId, "values": values,
    "actions": [{"choice": 0}, {"choice": 1}]}

proc step(command: JsonNode): JsonNode =
  if command["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  let action = parseJson(command["response"].getStr())
  let choice = action["choice"].getInt()
  doAssert choice in 0 .. 1
  choices[seat] = choice
  inc decisionId
  inc seat
  if seat == game.seatCount():
    let world = BaselineWorld(map: game.map, trains: game.trains,
      occ: game.occ, waitsFor: game.waitsFor, tick: game.tick,
      params: DefaultBaselineParams)
    var directives: seq[Directive]
    for player in 0 ..< game.seatCount():
      let kind = if choices[player] == 0: blTimetable else: blYielder
      directives.add(scriptedDirective(world, kind, game.contextFor(player)))
    for directive in directives:
      for order in directive.orders:
        game.applyOrder(order.train,
          TrainOrder(verb: order.verb, arg: order.arg))
    game.closeTurn()
    game.step()
    while game.phase == Playing and game.tick mod game.config.turnTicks != 0:
      game.step()
    seat = 0
  let observation = if game.phase != Playing:
    let scores = parseJson(game.networkResultsJson())["scores"]
    var scoresBySeat = newJObject()
    var utilities = newJObject()
    for player in 0 ..< game.seatCount():
      scoresBySeat[$player] = scores[player]
      let score = scores[player].getFloat()
      utilities[$player] = %(score / (score + 1000.0))
    %*{"kind": "terminal", "scores": scoresBySeat,
      "utilities": utilities}
  else: currentDecision()
  %*{"kind": "accepted", "action": action, "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    quit("usage: flatland-train-bridge MANIFEST VARIANT", 1)
  manifestPath = absolutePath(args[0])
  variant = args[1]
  doAssert variant in ["mainline", "branchline"]
  for line in stdin.lines:
    let command = parseJson(line)
    let response = case command["kind"].getStr()
      of "reset": reset(command)
      of "encode": encode()
      of "teacher": %*{"response": $(%*{"choice": 0})}
      of "step": step(command)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
