## The manifest, the compose file, the policy set and the CI scaffold.
## Design note §Tests 33-34.

import std/[json, os, strutils]

import flatland/[sim, sim_config]
import ./helpers

echo "test_flatland_manifest"

let doc = manifest()

# 33. manifest pins ----------------------------------------------------------
check "num_agents is inside every game_config and never at a variant top level":
  for variant in doc{"variants"}:
    doAssert variant{"game_config"}{"num_agents"}.getInt() == 4,
      "variant " & variant{"id"}.getStr() & " is missing num_agents"
    doAssert not variant.hasKey("num_agents"),
      "CoworldVariant is additionalProperties:false — num_agents belongs in " &
      "game_config (the goofspiel-oshi-zumo 0.1.0 scar)"
  doAssert doc{"certification"}{"game_config"}{"num_agents"}.getInt() == 4

check "no game_config carries a literal tokens array":
  proc scan(node: JsonNode, where: string) =
    doAssert not node.hasKey("tokens"),
      where & " carries a runner-managed tokens array (knights-archers 0.1.0)"
  for variant in doc{"variants"}:
    scan(variant{"game_config"}, "variant " & variant{"id"}.getStr())
  scan(doc{"certification"}{"game_config"}, "the certification fixture")
  var required: seq[string]
  for entry in doc{"game"}{"config_schema"}{"required"}:
    required.add(entry.getStr())
  doAssert "tokens" in required,
    "config_schema must still REQUIRE tokens: the runner injects them"

check "every declared player occupies a certification slot":
  var declared: seq[string]
  for entry in doc{"player"}:
    declared.add(entry{"id"}.getStr())
  doAssert declared.len == 2, "expected two declared players, got " & $declared
  var seated: seq[string]
  for entry in doc{"certification"}{"players"}:
    seated.add(entry{"player_id"}.getStr())
  for id in declared:
    doAssert id in seated,
      "player[] declares " & id & " but the cert fixture never seats it (raid 0.1.2)"
  doAssert seated.len == 4
  doAssert doc{"certification"}{"game_config"}{"players"}.len == 4

check "every array in config_schema declares minItems and maxItems":
  for name, prop in doc{"game"}{"config_schema"}{"properties"}:
    if prop{"type"}.getStr() != "array":
      continue
    doAssert prop.hasKey("minItems") and prop.hasKey("maxItems"),
      "config_schema." & name & " is an array without minItems/maxItems (tandem 0.1.0)"

check "the top-level shape the 0.1.42 upload contract wants":
  doAssert doc.hasKey("$schema")
  doAssert doc{"tags"}.len >= 3
  doAssert doc{"episode_timeout_minutes"}.getInt() == 20,
    "episode_timeout_minutes is TOP LEVEL, not under game"
  doAssert not doc{"game"}.hasKey("episode_timeout_minutes")
  doAssert not doc.hasKey("version"), "no top-level version"
  doAssert not doc.hasKey("name") and not doc.hasKey("description"),
    "top level is additionalProperties:false — name/description live under game"
  doAssert not doc{"game"}.hasKey("display_name")
  doAssert not doc{"game"}.hasKey("tags"), "game.tags is forbidden (pistonball 0.1.0)"
  doAssert doc{"game"}{"description"}.getStr().len > 0
  doAssert doc{"game"}{"owner"}.getStr().len > 0
  doAssert doc{"game"}{"runnable"}{"type"}.getStr() == "game"
  doAssert doc{"game"}{"replay_viewer"}{"bundle"}.getStr() == "static-replay-viewer"
  doAssert not doc.hasKey("replay_viewer"), "replay_viewer lives UNDER game"
  for variant in doc{"variants"}:
    doAssert variant{"description"}.getStr().len > 0

check "both protocols are {type,value} objects and the docs carry readme + pages":
  for key in ["player", "global"]:
    let node = doc{"game"}{"protocols"}{key}
    doAssert node != nil, "game.protocols." & key & " is missing (garble v0.1.0)"
    doAssert node.kind == JObject and node.hasKey("type") and node.hasKey("value"),
      "game.protocols." & key & " must be an object, never a bare string"
  let docs = doc{"game"}{"docs"}
  doAssert docs{"readme"}.hasKey("type") and docs{"readme"}.hasKey("value")
  doAssert docs{"pages"}.len == 3
  for page in docs{"pages"}:
    doAssert page.hasKey("id") and page.hasKey("title")
    doAssert page{"content"}.hasKey("type") and page{"content"}.hasKey("value")

check "every declared player's cpu limit is at least 1":
  for entry in doc{"player"}:
    let cpu = entry{"resources"}{"limits"}{"cpu"}.getStr()
    doAssert cpu == "1" or (cpu.len > 1 and not cpu.endsWith("m") and
                            parseFloat(cpu) >= 1.0),
      "player[].resources.limits.cpu is " & cpu & ", minimum is \"1\" (pistonball 0.1.1)"

check "the secret namespace is game.name and the game pod receives the key":
  let name = doc{"game"}{"name"}.getStr()
  doAssert name == GameName
  doAssert doc{"game"}{"runnable"}{"env"}{"ANTHROPIC_API_KEY_URI"}.getStr() ==
    "secret://coworld/" & name & "/anthropic_api_key",
    "the secret namespace must equal game.name (cooperative-hunting 2026-08-25)"

check "every wallClockBudgetSeconds is inside 60% of the episode timeout":
  let cap = doc{"episode_timeout_minutes"}.getInt() * 60
  for variant in doc{"variants"}:
    let budget = variant{"game_config"}{"wallClockBudgetSeconds"}.getInt()
    doAssert budget <= MaxWallClockBudgetSeconds
    doAssert budget * 100 < cap * 60
  doAssert doc{"certification"}{"game_config"}{"wallClockBudgetSeconds"}.getInt() <=
    MaxWallClockBudgetSeconds

check "every variant's game_config actually constructs and plays":
  # the collab-cooking 0.1.1 scar: test EVERY variant, not just the fixture.
  var fixtures = @[doc{"certification"}{"game_config"}]
  for variant in doc{"variants"}:
    fixtures.add(variant{"game_config"})
  for fixture in fixtures:
    var config = defaultGameConfig()
    config.update(fixture)
    let game = newSimServer(config)
    doAssert game.trains.len == config.numAgents * config.trainsPerSeat
    var speeds = newSeq[int](5)
    for train in game.trains:
      inc speeds[train.ticksPerCell]
    for speed in 1 .. 4:
      doAssert speeds[speed] == game.trains.len div 4,
        "the speed multiset must be exactly " & $(game.trains.len div 4) &
        " of each class, got " & $speeds[speed] & " of class " & $speed
    doAssert config.parOnTime <= game.trains.len
    doAssert game.map.pool == config.networkPool
    game.startPlaying()
    for _ in 0 ..< 64:
      if game.phase != Playing:
        break
      game.step()
    doAssert game.tick > 0

# 34. the CI scaffold --------------------------------------------------------
check "compose declares ONE service whose name derives the image placeholder":
  let compose = readRepoFile("compose.yaml")
  doAssert "services:" in compose
  doAssert "  flatland:" in compose
  doAssert "image: coworld-flatland:latest" in compose
  doAssert "platform: linux/amd64" in compose
  doAssert "network: host" in compose
  var services = 0
  for line in compose.splitLines():
    if line.startsWith("  ") and line.strip().endsWith(":") and
        not line.startsWith("   "):
      inc services
  doAssert services == 1, "exactly one compose service (lantern 0.1.0)"
  doAssert doc{"game"}{"runnable"}{"image"}.getStr() == "{{FLATLAND_IMAGE}}",
    "the image placeholder lives on game.runnable, not on game " &
    "(coworld 0.1.43 bundle.py `_load_template_manifest`)"
  for entry in doc{"player"}:
    doAssert entry{"image"}.getStr() == "{{FLATLAND_IMAGE}}"

check "the policy set is two prompt champions plus two scripted fillers":
  let policies = parseJson(readRepoFile("tools/ci/policies.json"))
  doAssert policies.len == 4
  var prompts = 0
  var scripted = 0
  for policy in policies:
    doAssert policy{"run"}.getStr() == "/bin/flatland-player"
    doAssert policy{"name"}.getStr().startsWith("flatland-")
    doAssert not policy{"env"}.hasKey("USE_BEDROCK"),
      "the LLM call is made by the GAME pod; no player-side Bedrock gate"
    if policy{"env"}.hasKey("PLAYER_PROMPT"):
      inc prompts
      doAssert policy{"env"}{"PLAYER_PROMPT"}.getStr().len > 200
    if policy{"env"}.hasKey("PLAYER_SCRIPTED"):
      inc scripted
      doAssert policy{"env"}{"PLAYER_SCRIPTED"}.getStr() in ["timetable", "yielder"]
  doAssert prompts == 2 and scripted == 2
  doAssert policies[0]{"env"}{"PLAYER_PROMPT"} != policies[1]{"env"}{"PLAYER_PROMPT"}
  doAssert policies[1]{"player"}.getStr() ==
    "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d",
    "champion #2 must be uploaded while daveey-1 is the active player"

check "the workflow scaffold is present, substituted and executable":
  for path in [".github/workflows/ci.yml", ".github/workflows/coworld-release.yml",
               ".github/workflows/coworld-submit.yml", "tools/ci/docker_smoke.sh",
               "tools/ci/viewer_smoke.mjs", "tools/ci/policies.json",
               "tools/build_replay_viewer.sh", "tools/ci/renderer_fixture.html"]:
    doAssert fileExists(repoRoot() / path), path & " is missing"
  for path in [".github/workflows/ci.yml", ".github/workflows/coworld-release.yml",
               ".github/workflows/coworld-submit.yml", "tools/ci/docker_smoke.sh",
               "tools/ci/policies.json"]:
    let text = readRepoFile(path)
    for placeholder in ["<slug>", "<IMAGE>", "<SEATS>"]:
      doAssert placeholder notin text,
        path & " still carries the unsubstituted placeholder " & placeholder
  let ci = readRepoFile(".github/workflows/ci.yml")
  doAssert "SMOKE_REQUIRE_REPLAY_JSON" in ci, "the replay is binary COWLDFLT"
  doAssert "--soak 10" in ci
  doAssert "--strict-text-bounds" in ci
  doAssert "renderer_fixture.html" in ci
  doAssert "needs: docker-smoke" in ci,
    "the viewer smoke must run against a FRESH replay from the same run"
  let release = readRepoFile(".github/workflows/coworld-release.yml")
  doAssert "--timeout-seconds 300" in release
  doAssert "release-result" in release
  doAssert "\"player\"" in release or "player_id" in release
  for name in ["version", "policies", "put_secret", "skip_certify"]:
    doAssert "      " & name & ":" in release, "release input " & name & " is missing"
  let submit = readRepoFile(".github/workflows/coworld-submit.yml")
  doAssert "submit-result" in submit
  for name in ["player_id", "policy", "league_id"]:
    doAssert "      " & name & ":" in submit, "submit input " & name & " is missing"
  when defined(posix):
    for path in ["tools/ci/docker_smoke.sh", "tools/build_replay_viewer.sh"]:
      let permissions = getFilePermissions(repoRoot() / path)
      doAssert fpUserExec in permissions,
        path & " must be committed executable (coworld build requires os.X_OK)"

check "the smoke seat cross-check agrees with the fixture":
  let smoke = readRepoFile("tools/ci/docker_smoke.sh")
  doAssert "seats_expected=\"${SMOKE_SEATS:-4}\"" in smoke
  doAssert "slug=\"${SMOKE_SLUG:-flatland}\"" in smoke
  doAssert "/bin/${slug}" in smoke

echo "test_flatland_manifest: ", checks, " checks ok"
