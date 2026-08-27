## The episode's resolved configuration: defaults, `config.update` from the
## runner's JSON, and the invariants the manifest's `config_schema` also
## states. Forked from `coworld-ctf`'s `src/ctf/sim_config.nim`.

import std/[json, strutils]

import sim_types, upstream

type
  GameConfig* = object
    seed*: uint64
    numAgents*: int
    minPlayers*: int
    networkPool*: string
    trainsPerSeat*: int
    maxTicks*: int
    turnTicks*: int
    parOnTime*: int
    slackTicks*: int
    minJourneyCells*: int
    departStagger*: int
    malfunctionRate*: int
    malfunctionMinDuration*: int
    malfunctionMaxDuration*: int
    jamTicks*: int
    deadlockTicks*: int
    quiesceTicks*: int
    attempt1Ms*: int
    retryMs*: int
    turnBudgetMs*: int
    turnSpacingMs*: int
    wallClockBudgetSeconds*: int
    lobbyJoinTimeoutTicks*: int
    gameOverTicks*: int
    fastMode*: bool
    showPlayerLabels*: bool
    maxOutputTokens*: int
    model*: string
    playerNames*: seq[string]
    tokens*: seq[string]
    slots*: seq[int]

const
  DefaultTrainsPerSeat* = 6
  DefaultTurnTicks* = 16
  DefaultSlackTicks* = 24
  DefaultMinJourneyCells* = 12
  DefaultDepartStagger* = 4
  DefaultJamTicks* = 12
  DefaultDeadlockTicks* = 24
  DefaultQuiesceTicks* = 120
  MaxWallClockBudgetSeconds* = 660
    ## 660 s is the engine's own stop. 720 s is 60 % of the platform's assumed
    ## 1200 s `episodeTimeoutSeconds`; every shipped variant sits under it and
    ## `tests/test_flatland_manifest.nim` asserts it.

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 1,
    numAgents: 4,
    minPlayers: 4,
    networkPool: "mainline",
    trainsPerSeat: DefaultTrainsPerSeat,
    maxTicks: DefaultMaxTicks,
    turnTicks: DefaultTurnTicks,
    parOnTime: 15,
    slackTicks: DefaultSlackTicks,
    minJourneyCells: DefaultMinJourneyCells,
    departStagger: DefaultDepartStagger,
    malfunctionRate: 300,
    malfunctionMinDuration: 8,
    malfunctionMaxDuration: 24,
    jamTicks: DefaultJamTicks,
    deadlockTicks: DefaultDeadlockTicks,
    quiesceTicks: DefaultQuiesceTicks,
    attempt1Ms: 9000,
    retryMs: 4000,
    turnBudgetMs: 14000,
    turnSpacingMs: 12000,
    wallClockBudgetSeconds: MaxWallClockBudgetSeconds,
    lobbyJoinTimeoutTicks: 2400,
    gameOverTicks: 24,
    fastMode: true,
    showPlayerLabels: false,
    maxOutputTokens: 900,
    model: "claude-haiku-4-5-20251001",
    playerNames: @[],
    tokens: @[],
    slots: @[]
  )

proc trainCount*(config: GameConfig): int {.inline.} =
  config.numAgents * config.trainsPerSeat

proc turnsPerEpisode*(config: GameConfig): int {.inline.} =
  ## Turns fire at ticks 0, turnTicks, 2*turnTicks, ... < maxTicks.
  if config.turnTicks <= 0:
    1
  else:
    (max(0, config.maxTicks - 1) div config.turnTicks) + 1

proc getIntField(node: JsonNode, key: string, fallback: int): int =
  let value = node{key}
  if value.isNil:
    return fallback
  case value.kind
  of JInt: int(value.getBiggestInt())
  of JFloat: int(value.getFloat())
  of JString:
    try: parseInt(value.getStr()) except CatchableError: fallback
  else: fallback

proc getBoolField(node: JsonNode, key: string, fallback: bool): bool =
  let value = node{key}
  if value.isNil:
    return fallback
  case value.kind
  of JBool: value.getBool()
  of JInt: value.getBiggestInt() != 0
  else: fallback

proc validate*(config: GameConfig) =
  if config.numAgents != MaxSeats:
    raise newException(FlatlandError,
      "num_agents must be " & $MaxSeats & ", got " & $config.numAgents)
  if config.trainsPerSeat < 3 or config.trainsPerSeat > 8:
    raise newException(FlatlandError, "trainsPerSeat must be 3..8")
  if config.trainCount() mod SpeedClasses.len != 0:
    raise newException(FlatlandError,
      "trainCount must divide by " & $SpeedClasses.len & " so the speed multiset is exact")
  if config.trainCount() > MaxTrains:
    raise newException(FlatlandError, "trainCount exceeds MaxTrains")
  if config.networkPool != "mainline" and config.networkPool != "branchline":
    raise newException(FlatlandError, "networkPool must be mainline|branchline")
  if config.maxTicks <= 0 or config.turnTicks <= 0:
    raise newException(FlatlandError, "maxTicks and turnTicks must be positive")
  if config.malfunctionRate <= 0:
    raise newException(FlatlandError, "malfunctionRate must be positive")
  if config.malfunctionMinDuration <= 0 or
      config.malfunctionMaxDuration < config.malfunctionMinDuration:
    raise newException(FlatlandError, "malfunction durations are inverted")
  if config.wallClockBudgetSeconds > MaxWallClockBudgetSeconds:
    raise newException(FlatlandError,
      "wallClockBudgetSeconds must be <= " & $MaxWallClockBudgetSeconds)
  # curly hands the attempt deadline to CURLOPT_TIMEOUT, whose granularity is
  # WHOLE SECONDS, so a sub-second value is not the deadline it claims to be.
  if config.attempt1Ms > 0 and config.attempt1Ms < 1000:
    raise newException(FlatlandError, "attempt1Ms must be 0 or >= 1000")
  if config.retryMs > 0 and config.retryMs < 1000:
    raise newException(FlatlandError, "retryMs must be 0 or >= 1000")

proc update*(config: var GameConfig, node: JsonNode) =
  ## Applies the runner's `COGAME_CONFIG_URI` document. Unknown keys are
  ## ignored; `tokens` is runner-injected and never appears in a manifest
  ## `game_config`.
  if node.isNil or node.kind != JObject:
    return
  let seedNode = node{"seed"}
  if not seedNode.isNil and seedNode.kind in {JInt, JFloat}:
    config.seed = uint64(seedNode.getBiggestInt())
  config.numAgents = node.getIntField("num_agents", config.numAgents)
  config.minPlayers = node.getIntField("minPlayers", config.minPlayers)
  let pool = node{"networkPool"}
  if not pool.isNil and pool.kind == JString:
    config.networkPool = pool.getStr()
  config.trainsPerSeat = node.getIntField("trainsPerSeat", config.trainsPerSeat)
  config.maxTicks = node.getIntField("maxTicks", config.maxTicks)
  config.turnTicks = node.getIntField("turnTicks", config.turnTicks)
  config.parOnTime = node.getIntField("parOnTime", config.parOnTime)
  config.slackTicks = node.getIntField("slackTicks", config.slackTicks)
  config.minJourneyCells = node.getIntField("minJourneyCells", config.minJourneyCells)
  config.departStagger = node.getIntField("departStagger", config.departStagger)
  config.malfunctionRate = node.getIntField("malfunctionRate", config.malfunctionRate)
  config.malfunctionMinDuration =
    node.getIntField("malfunctionMinDuration", config.malfunctionMinDuration)
  config.malfunctionMaxDuration =
    node.getIntField("malfunctionMaxDuration", config.malfunctionMaxDuration)
  config.jamTicks = node.getIntField("jamTicks", config.jamTicks)
  config.deadlockTicks = node.getIntField("deadlockTicks", config.deadlockTicks)
  config.quiesceTicks = node.getIntField("quiesceTicks", config.quiesceTicks)
  config.attempt1Ms = node.getIntField("attempt1Ms", config.attempt1Ms)
  config.retryMs = node.getIntField("retryMs", config.retryMs)
  config.turnBudgetMs = node.getIntField("turnBudgetMs", config.turnBudgetMs)
  config.turnSpacingMs = node.getIntField("turnSpacingMs", config.turnSpacingMs)
  config.wallClockBudgetSeconds =
    node.getIntField("wallClockBudgetSeconds", config.wallClockBudgetSeconds)
  config.lobbyJoinTimeoutTicks =
    node.getIntField("lobbyJoinTimeoutTicks", config.lobbyJoinTimeoutTicks)
  config.gameOverTicks = node.getIntField("gameOverTicks", config.gameOverTicks)
  config.fastMode = node.getBoolField("fastMode", config.fastMode)
  config.showPlayerLabels =
    node.getBoolField("showPlayerLabels", config.showPlayerLabels)
  config.maxOutputTokens = node.getIntField("maxOutputTokens", config.maxOutputTokens)
  let model = node{"model"}
  if not model.isNil and model.kind == JString and model.getStr().len > 0:
    config.model = model.getStr()
  let players = node{"players"}
  if not players.isNil and players.kind == JArray:
    config.playerNames = @[]
    for entry in players:
      if entry.kind == JObject:
        config.playerNames.add(entry{"name"}.getStr())
      elif entry.kind == JString:
        config.playerNames.add(entry.getStr())
  let tokens = node{"tokens"}
  if not tokens.isNil and tokens.kind == JArray:
    config.tokens = @[]
    for entry in tokens:
      config.tokens.add(entry.getStr())
  let slots = node{"slots"}
  if not slots.isNil and slots.kind == JArray:
    config.slots = @[]
    for entry in slots:
      config.slots.add(int(entry.getBiggestInt()))
  config.validate()

proc resolvedConfigJson*(config: GameConfig, network: string): string =
  ## The config block the replay carries: everything the viewer needs to
  ## reconstruct the episode, and never a token.
  var players = newJArray()
  for name in config.playerNames:
    players.add(%*{"name": name})
  $(%*{
    "seed": config.seed.int64,
    "network": network,
    "num_agents": config.numAgents,
    "trainsPerSeat": config.trainsPerSeat,
    "maxTicks": config.maxTicks,
    "turnTicks": config.turnTicks,
    "parOnTime": config.parOnTime,
    "slackTicks": config.slackTicks,
    "minJourneyCells": config.minJourneyCells,
    "departStagger": config.departStagger,
    "malfunctionRate": config.malfunctionRate,
    "minDuration": config.malfunctionMinDuration,
    "maxDuration": config.malfunctionMaxDuration,
    "jamTicks": config.jamTicks,
    "deadlockTicks": config.deadlockTicks,
    "quiesceTicks": config.quiesceTicks,
    "fastMode": config.fastMode,
    "showPlayerLabels": config.showPlayerLabels,
    "players": players,
    "slots": config.slots
  })
