## Complete native rail episodes with hosted prompts and scripted dispatch.

import std/[json, os, osproc, strutils]
import flatland/[sim, decide, baselines, directives, llm, roster]

when isMainModule:
  let args = commandLineParams()
  if args.len != 3:
    quit("usage: flatland-posttrain OUTPUT EPISODES VARIANT", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  if episodes < 10: quit("at least ten games are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update(variantConfig)
    let game = newSimServer(config)
    game.startPlaying()
    let briefing = $game.networkBriefing()
    var rows: seq[string]
    while game.phase == Playing:
      if game.tick mod config.turnTicks == 0:
        let turnIndex = game.tick div config.turnTicks + 1
        game.turn = turnIndex
        let world = BaselineWorld(map: game.map, trains: game.trains,
          occ: game.occ, waitsFor: game.waitsFor, tick: game.tick,
          params: DefaultBaselineParams)
        var directives: seq[Directive]
        for seat in 0 ..< game.seatCount():
          let context = game.contextFor(seat)
          let baseline = if seat mod 2 == 0: blTimetable else: blYielder
          let directive = scriptedDirective(world, baseline, context)
          var orders = newJArray()
          for order in directive.orders:
            if game.trains[order.train].state == tsArrived: continue
            var entry = %*{"train": trainId(order.train),
              "verb": $order.verb}
            if order.verb == ovSiding: entry["at"] = %order.arg
            elif order.verb == ovRoute: entry["via"] = %order.arg
            orders.add(entry)
          let reply = %*{"orders": orders, "say": directive.say,
            "notes": directive.notes}
          let accepted = parseDirective(reply, context)
          doAssert accepted.rejected == 0
          doAssert accepted.orders.len == directive.orders.len
          for index, order in directive.orders:
            doAssert accepted.orders[index].train == order.train
            doAssert accepted.orders[index].verb == order.verb
            doAssert accepted.orders[index].arg == order.arg
          directives.add(accepted)
          let view = game.seatObservation(seat, turnIndex,
            config.turnsPerEpisode())
          rows.add($(%*{
            "episode_id": "flatland-" & variant & "-" & $seed,
            "seed": "flatland-" & variant & "-" & $seed,
            "decision_id": rows.len,
            "prompt": [
              {"role": "system", "content": SystemPrompt},
              {"role": "user", "content": userMessage(briefing, "", $view)}
            ],
            "completion": [{"role": "assistant", "content": $reply}],
            "game": "flatland",
            "action_schema_revision": "flatland-directive-v1"
          }))
        for directive in directives:
          for order in directive.orders:
            game.applyOrder(order.train,
              TrainOrder(verb: order.verb, arg: order.arg))
        game.closeTurn()
      game.step()
    doAssert game.tick <= config.maxTicks
    let results = parseJson(game.networkResultsJson())
    if seed mod 5 == 0: validationRows.add(rows)
    else: trainRows.add(rows)
    runs.add(%*{"seed": seed, "turns": rows.len div game.seatCount(),
      "ticks": game.tick, "scores": results["scores"],
      "reason": results["reason"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "flatland", "variant": variant,
    "source_revision": revision, "teacher": "timetable-vs-yielder",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len, "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
