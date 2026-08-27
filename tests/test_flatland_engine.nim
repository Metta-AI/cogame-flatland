## The end-to-end episode and the replay. Design note §Tests 25-32.
##
## These run a REAL four-seat episode against a temp-dir `COGAME_*` URI set —
## the game server binary's own loop, its own artifact writes — with no API
## key, so the LLM client disables itself and every seat plays its scripted
## baseline.

import std/[algorithm, json, os, osproc, streams, strtabs, strutils, times]

import flatland/[sim, baselines, directives, replays, replay_runtime, roster,
                 events, decide]
import ./helpers

echo "test_flatland_engine"

proc runEpisode(seats: array[4, string], config: JsonNode,
                extraEnv: seq[(string, string)] = @[]):
    tuple[results: JsonNode, replay: string, log: string, exit: int] =
  ## Starts the built game binary and one player process per seat, exactly as
  ## `tools/ci/docker_smoke.sh` does but without Docker.
  let root = repoRoot()
  let work = getTempDir() / ("flatland-e2e-" & $getCurrentProcessId() & "-" &
                             $epochTime().int)
  createDir(work)
  writeFile(work / "config.json", $config)
  let gameBin = work / "flatland"
  let playerBin = work / "flatland-player"
  doAssert execCmd("nim c -d:release --hints:off --path:" & root / "src" &
    " -o:" & gameBin & " " & root / "src" / "flatland.nim") == 0
  doAssert execCmd("nim c -d:release --hints:off --path:" & root / "src" &
    " -o:" & playerBin & " " & root / "src" / "flatland_player.nim") == 0
  let port = 8300 + (getCurrentProcessId() mod 400)
  var env = @[
    ("COGAME_HOST", "127.0.0.1"), ("COGAME_PORT", $port),
    ("COGAME_CONFIG_URI", "file://" & work / "config.json"),
    ("COGAME_RESULTS_URI", "file://" & work / "results.json"),
    ("COGAME_SAVE_REPLAY_URI", "file://" & work / "episode.replay"),
    ("COGAME_PLAYER_FAILURE_URI", "file://" & work / "player_failure.json"),
    ("COGAME_EVENTS_URI", "file://" & work / "events.jsonl")]
  for pair in extraEnv:
    env.add(pair)
  var envTable = newStringTable()
  for pair in env:
    envTable[pair[0]] = pair[1]
  let game = startProcess(gameBin, options = {poStdErrToStdOut},
                          env = envTable)
  var players: seq[Process]
  for slot, baseline in seats:
    if baseline.len == 0:
      continue
    var playerEnv = newStringTable()
    playerEnv["COWORLD_PLAYER_WS_URL"] =
      "ws://127.0.0.1:" & $port & "/player?slot=" & $slot & "&token=token-" & $slot
    playerEnv["PLAYER_SCRIPTED"] = baseline
    playerEnv["PLAYER_POLICY_LABEL"] = baseline
    playerEnv["PATH"] = getEnv("PATH")
    players.add(startProcess(playerBin, options = {poStdErrToStdOut},
                             env = playerEnv))
  result.exit = game.waitForExit(timeout = 300_000)
  result.log = game.outputStream.readAll()
  game.close()
  for player in players:
    discard player.waitForExit(timeout = 30_000)
    player.close()
  if fileExists(work / "results.json"):
    result.results = parseJson(readFile(work / "results.json"))
  else:
    result.results = newJObject()
  if fileExists(work / "episode.replay"):
    result.replay = readFile(work / "episode.replay")
  if fileExists(work / "player_failure.json"):
    result.log.add("\nPLAYER FAILURE: " & readFile(work / "player_failure.json"))
    result.results["__failurePayload"] = parseJson(
      readFile(work / "player_failure.json"))
  removeDir(work)

proc fixtureConfig(overrides: JsonNode = nil): JsonNode =
  result = %*{
    "players": [{"name": "Alpha"}, {"name": "Beta"}, {"name": "Gamma"},
                {"name": "Delta"}],
    "num_agents": 4, "minPlayers": 4, "seed": 42,
    "networkPool": "mainline", "trainsPerSeat": 6,
    "maxTicks": 200, "turnTicks": 16, "parOnTime": 15, "slackTicks": 24,
    "minJourneyCells": 12, "departStagger": 4,
    "malfunctionRate": 300, "malfunctionMinDuration": 8,
    "malfunctionMaxDuration": 24,
    "jamTicks": 12, "deadlockTicks": 24, "quiesceTicks": 120,
    "wallClockBudgetSeconds": 120, "lobbyJoinTimeoutTicks": 240,
    "gameOverTicks": 0,
    "fastMode": true, "showPlayerLabels": false,
    "tokens": ["token-0", "token-1", "token-2", "token-3"]
  }
  if overrides != nil:
    for key, value in overrides:
      result[key] = value

# 25. the episode writes its artifacts ---------------------------------------
let episode = runEpisode(["yielder", "timetable", "yielder", "timetable"],
                         fixtureConfig())

check "a real four-seat episode writes results and a replay and exits 0":
  doAssert episode.exit == 0, "the game exited " & $episode.exit & "\n" & episode.log
  doAssert episode.replay.len > 0, "no replay was written\n" & episode.log
  doAssert episode.results{"reason"}.getStr() == "complete",
    "reason " & episode.results{"reason"}.getStr() & "\n" & episode.log
  doAssert episode.results{"arrivedTotal"}.getInt() > 0
  let onTime = episode.results{"fleetOnTime"}.getInt()
  let arrived = episode.results{"arrivedTotal"}.getInt()
  for slot in 0 ..< 4:
    doAssert episode.results{"scores"}[slot].getInt() ==
      1000 * onTime + 10 * arrived + episode.results{"onTime"}[slot].getInt()

check "the results key set equals the manifest results_schema exactly":
  let schema = manifest(){"game"}{"results_schema"}{"properties"}
  var schemaKeys: seq[string]
  for key, _ in schema:
    schemaKeys.add(key)
  var got: seq[string]
  for key, _ in episode.results:
    if key.startsWith("__"):
      continue
    got.add(key)
  for key in got:
    doAssert key in schemaKeys, "results.json has an undeclared key: " & key
  for key in schemaKeys:
    doAssert key in got, "results_schema declares a key results.json omits: " & key
  doAssert allResultsKeys().len == schemaKeys.len

# 26. the cert seed is interesting -------------------------------------------
check "seed 42 exercises arrivals AND the breakdown path inside 200 ticks":
  doAssert episode.results{"arrivedTotal"}.getInt() > 0
  doAssert episode.results{"malfunctions"}.getInt() > 0,
    "the CI smoke replay must always exercise the breakdown path"

# 27. no seat can stall the episode ------------------------------------------
check "a seat that never connects does not stop the clock":
  let starved = runEpisode(["yielder", "timetable", "yielder", ""],
                           fixtureConfig(%*{"minPlayers": 3,
                                            "lobbyJoinTimeoutTicks": 120}))
  doAssert starved.exit == 0, starved.log
  doAssert starved.results{"reason"}.getStr() == "complete", starved.log
  doAssert starved.results{"deadSeats"}[3].getBool(),
    "the absent seat must be reported dead"
  doAssert starved.results{"arrivedTotal"}.getInt() >= 0
  let payload = starved.results{"__failurePayload"}
  if payload != nil:
    var keys: seq[string]
    for key, _ in payload:
      keys.add(key)
    keys.sort(cmp)
    doAssert keys == @["failed_policy_index", "message"],
      "the player-failure payload is CLOSED: " & $keys

# 28. the budget guard settles early -----------------------------------------
check "the budget guard drops to scripted rather than overrunning":
  let game = playScripted(5, [blYielder, blYielder, blYielder, blYielder],
                          maxTicks = 64)
  var engine = initDecisionEngine(game)
  for seat in 0 ..< 4:
    engine.seats[seat].isLlm = true
  # elapsed is already past the point where two more turns would fit
  let outcome = engine.turn(game, 1, game.config.wallClockBudgetSeconds - 1)
  doAssert engine.llmOff, "the budget guard must fire"
  var sawGuard = false
  for record in outcome.records:
    if parseJson(record){"k"}.getStr() == "budget_guard":
      sawGuard = true
  doAssert sawGuard, "a budget_guard record must name the turn"
  for directive in outcome.directives:
    doAssert directive.orders.len > 0, "no failure path may leave a train idle"

check "an LLM seat with no credentials records a fallback, not a scripted turn":
  let game = playScripted(6, [blYielder, blYielder, blYielder, blYielder],
                          maxTicks = 64)
  var engine = initDecisionEngine(game)
  engine.seats[0].isLlm = true
  let outcome = engine.turn(game, 1, 0)
  var causes: seq[string]
  for record in outcome.records:
    let node = parseJson(record)
    if node{"k"}.getStr() == "fallback":
      causes.add(node{"cause"}.getStr())
  doAssert "no_credentials" in causes, $causes
  doAssert outcome.directives[0].source == dsFallback

check "a seat that never registered is a DISCONNECTED fallback, not scripted":
  # `cause` is a closed enum of seven in the design note; `disconnected` was
  # the one no path could produce, because an unregistered seat fell through to
  # the scripted branch and was recorded as a policy it never chose.
  let game = playScripted(7, [blYielder, blYielder, blYielder, blYielder],
                          maxTicks = 64)
  var engine = initDecisionEngine(game)
  for seat in 0 ..< 4:
    engine.seats[seat].registered = seat < 3
  let outcome = engine.turn(game, 1, 0)
  var causes: seq[string]
  for record in outcome.records:
    let node = parseJson(record)
    if node{"k"}.getStr() == "fallback":
      causes.add(node{"cause"}.getStr() & "/" & $node{"slot"}.getInt())
  doAssert "disconnected/3" in causes, $causes
  doAssert outcome.directives[3].source == dsFallback
  doAssert outcome.directives[3].orders.len > 0,
    "a dead seat's fleet still gets orders"
  for seat in 0 ..< 3:
    doAssert outcome.directives[seat].source == dsScripted,
      "a registered scripted seat is not a fallback"

echo "test_flatland_engine: ", checks, " checks ok"
