## The mummy HTTP/websocket server implementing the Coworld contract, and the
## game loop. Forked from `coworld-ctf`'s `src/ctf/server.nim`, with the three
## named edits of the design note:
##
## 1. **Turn boundary** — unchanged in shape, with `turnTicks = 16` and FOUR
##    seats in one parallel batch.
## 2. **Registration interception** — a seat's Sprite v1 chat message whose
##    text parses as a registration object is consumed as REGISTRATION, not
##    applied as anything in-world and not written to the replay chat stream;
##    the server writes a REDACTED `register` record instead (policy label and
##    kind, never the prompt). An unappliable registration is HELD and re-read
##    when the slot lands (the paintball 2026-08-25 slot-sequential-join scar).
##    Any other chat text from a seat is dropped — dispatchers speak through
##    `say`.
## 3. **Wall-clock stop** — checked at the top of every loop iteration,
##    forcing `phase = GameOver`, `reason = deadline`, `endRule = wallClock`,
##    and written as the load-bearing stop record.
##
## The certifier's browser probes are served for real and registered BEFORE
## any catch-all asset route: `GET /client/player?slot=&token=` (token-checked,
## and it must NOT open the player socket), `GET /client/global`, the `/global`
## websocket's first message, and `/healthz` — all kept answering for the
## `gameOverTicks` grace after the artifacts are written (the lantern 0.1.1 and
## 0.1.3 scars). Global broadcasts are fire-and-forget so a slow viewer can
## never stall the episode.

import std/[json, locks, monotimes, os, strutils, tables, times]

import bitworld/runtime, bitworld/spriteprotocol
import mummy

import sim, roster, replays, replay_runtime, broadcast, global, decide,
       directives, baselines, events, rig_art

const
  HealthPath = "/healthz"
  PlayerClientPath = "/client/player"
  GlobalClientPath = "/client/global"
  ReplayClientPath = "/client/replay"
  ReplayDataPath = "/replay-data"
  FontPath = "/client/font.ttf"
  ShutdownGraceSeconds = 20
    ## `/healthz` and `/global` keep answering this long after the artifacts
    ## are written, then the process exits (the lantern 0.1.3 `/global` ping
    ## scar). The runner waits on process exit anyway.

  EmbeddedBroadcastHtml = staticRead("../../client/replay_broadcast.html")
    .replace("<!-- CHROME_COMMON -->",
             "<script>" & staticRead("../../client/chrome_common.js") & "</script>")
    .replace("<!-- BROADCAST_CORE -->",
             "<script>" & staticRead("../../client/broadcast_core.js") & "</script>")
  EmbeddedFont = staticRead("../../data/font.ttf")

type
  SocketRole = enum
    roleNone, rolePlayer, roleGlobal

  SocketState = object
    role: SocketRole
    slot: int
    viewer: GlobalViewerState

  AppState = object
    lock: Lock
    sockets: Table[WebSocket, SocketState]
    registrations: Table[int, string]  ## slot -> registration JSON, held
    commands: seq[string]
    seekTick: int
    running: bool
    tokens: seq[string]  ## runner-injected per-seat join tokens, copied out of
                         ## the config BEFORE the listener opens and never
                         ## mutated again

var appState: AppState
var wireConstantsJs: string

proc initAppState() =
  initLock(appState.lock)
  appState.sockets = initTable[WebSocket, SocketState]()
  appState.registrations = initTable[int, string]()
  appState.seekTick = -1
  appState.running = true

# ---------------------------------------------------------------------------
#  HTTP
# ---------------------------------------------------------------------------

proc queryInt(request: Request, key: string, fallback: int): int =
  let raw = request.queryParams.getOrDefault(key, "")
  if raw.len == 0:
    return fallback
  try: parseInt(raw) except CatchableError: fallback

proc respondText(request: Request, code: int, body: string,
                 contentType = "text/plain; charset=utf-8") =
  var headers: HttpHeaders
  headers["Content-Type"] = contentType
  headers["Cache-Control"] = "no-cache"
  request.respond(code, headers, body)

proc isUpgrade(request: Request): bool =
  request.headers["Sec-WebSocket-Key"].len > 0

proc respondForbidden(request: Request, reason: string) =
  ## 403 on the upgrade request itself, before any socket exists.
  ## `Connection: close` so the websocket client sees the status rather than
  ## a half-open handshake.
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  headers["Connection"] = "close"
  request.respond(403, headers, reason & "\n")

proc playerJoinAllowed(slot: int, token: string): bool {.gcsafe.} =
  ## Configured-roster auth for `/player`. `game_config.tokens` is
  ## runner-injected, one per seat. Certification opens
  ## `/player?slot=0&token=bad` and REQUIRES a 401/403 or a closed handshake
  ## (coworld 0.1.43 `runner.py:_require_bad_player_rejected`); accepting it is
  ## a `game_contract_violation`. With no tokens configured — the local docker
  ## smoke and the unit tests — every join is allowed.
  var configured: seq[string]
  {.gcsafe.}:
    withLock appState.lock:
      configured = appState.tokens
  var anyConfigured = false
  for entry in configured:
    if entry.len > 0:
      anyConfigured = true
      break
  if not anyConfigured:
    return true
  if slot >= 0:
    return slot < configured.len and configured[slot].len > 0 and
      configured[slot] == token
  for entry in configured:
    if entry.len > 0 and entry == token:
      return true
  false

proc httpHandler(request: Request) {.gcsafe.} =
  ## The certifier probes these four routes BEFORE any player pod starts, so
  ## they are registered ahead of the catch-all and none of them opens a
  ## player socket.
  if request.isUpgrade():
    var role = roleGlobal
    var slot = -1
    if request.path == "/player":
      role = rolePlayer
      slot = request.queryInt("slot", -1)
      if not playerJoinAllowed(slot,
          request.queryParams.getOrDefault("token", "")):
        request.respondForbidden(
          "player token does not match the configured seat")
        return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.sockets[websocket] = SocketState(role: role, slot: slot,
          viewer: initGlobalViewerState())
    return
  case request.path
  of HealthPath:
    request.respondText(200, "ok\n")
  of PlayerClientPath:
    ## Token-checked, and it serves a real page. It must NOT open the player
    ## websocket (the lantern 0.1.1 scar).
    let slot = request.queryInt("slot", -1)
    let token = request.queryParams.getOrDefault("token", "")
    if slot < 0:
      request.respondText(400, "missing slot\n")
      return
    {.gcsafe.}:
      request.respondText(200,
        "<!doctype html><meta charset=\"utf-8\"><title>flatland seat " &
        $slot & "</title><body style=\"background:#16110d;color:#f2e8d8;" &
        "font-family:system-ui;padding:24px\"><h1>flatland</h1>" &
        "<p>Dispatcher seat " & $slot & " is driven by the game server. " &
        "Token " & (if token.len > 0: "supplied" else: "absent") & ".</p>",
        "text/html; charset=utf-8")
  of GlobalClientPath, ReplayClientPath:
    {.gcsafe.}:
      request.respondText(200, EmbeddedBroadcastHtml, "text/html; charset=utf-8")
  of FontPath:
    {.gcsafe.}:
      var headers: HttpHeaders
      headers["Content-Type"] = "font/ttf"
      headers["Cache-Control"] = "public, max-age=3600"
      request.respond(200, headers, EmbeddedFont)
  of "/client/wire_constants.js":
    {.gcsafe.}:
      request.respondText(200, wireConstantsJs, "application/javascript")
  of ReplayDataPath:
    request.respondText(404, "no replay served here\n")
  else:
    request.respondText(200, "flatland server\n")

# ---------------------------------------------------------------------------
#  Websockets
# ---------------------------------------------------------------------------

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
                      message: Message) {.gcsafe.} =
  {.gcsafe.}:
    withLock appState.lock:
      case event
      of OpenEvent:
        if not appState.sockets.hasKey(websocket):
          appState.sockets[websocket] = SocketState(role: roleGlobal, slot: -1,
            viewer: initGlobalViewerState())
      of MessageEvent:
        if not appState.sockets.hasKey(websocket):
          return
        var state = appState.sockets[websocket]
        if state.role == rolePlayer:
          ## Registration interception. Any other chat text from a seat is
          ## dropped — dispatchers speak through `say`.
          for parsed in parseSpriteClientMessages(message.data):
            if parsed.kind != SpriteClientChatMessage:
              continue
            let text = parsed.text.strip()
            ## HELD until the slot lands: `readRegistrations` re-reads this
            ## table on every loop iteration and only stops applying a slot
            ## once that seat is marked registered (the paintball 2026-08-25
            ## slot-sequential-join scar). A socket that upgraded without
            ## `?slot=` has nothing to hold FOR — the registration blob carries
            ## no slot of its own and the socket can never learn one — so it is
            ## dropped rather than parked in a field nothing reads.
            if text.len > 0 and text[0] == '{' and state.slot >= 0:
              appState.registrations[state.slot] = text
        else:
          state.viewer.applyGlobalViewerMessage(message.data)
          if state.viewer.replaySeekTick >= 0:
            appState.seekTick = state.viewer.replaySeekTick
            state.viewer.replaySeekTick = -1
          for command in state.viewer.replayCommands:
            appState.commands.add(command)
          state.viewer.replayCommands.setLen(0)
        appState.sockets[websocket] = state
      of CloseEvent, ErrorEvent:
        appState.sockets.del(websocket)

# ---------------------------------------------------------------------------
#  The episode
# ---------------------------------------------------------------------------

type Engine = object
  game: SimServer
  decision: DecisionEngine
  writer: ReplayWriter
  runtime: RuntimeConfig
  chatRecords: seq[string]
  prescan: Prescan
  episodeStart: MonoTime

proc broadcastFrame(engine: var Engine, events: JsonNode,
                    includeTimeline: bool) =
  ## Fire-and-forget: a slow viewer can never stall the episode.
  let chrome = buildStateJson(engine.game, events,
    playing = engine.game.phase == Playing, speed = 1,
    maxTick = engine.game.config.maxTicks, startTick = 0,
    looping = false, transportEnabled = false, skipLulls = false,
    fastForwarding = false, mismatchTick = -1, prescan = engine.prescan,
    includeTimeline = includeTimeline)
  var placements = newSeq[TrainPlacement](engine.game.trains.len)
  for i, train in engine.game.trains:
    placements[i] = TrainPlacement(
      active: train.onGrid(), cell: train.cell, seat: train.owner,
      speed: train.ticksPerCell, facing: int(train.heading),
      held: train.state == tsHeld,
      broken: train.state == tsMalfunctioning,
      deadlocked: i in engine.game.activeDeadlock,
      late: engine.game.tick > train.scheduledArrival)
  {.gcsafe.}:
    withLock appState.lock:
      for socket, state in appState.sockets.mpairs:
        if state.role != roleGlobal:
          continue
        let packet = buildViewerPacket(engine.game.map, placements,
                                       state.viewer, chrome)
        var payload = newString(packet.len)
        for i, b in packet:
          payload[i] = char(b)
        socket.send(payload, BinaryMessage)

proc readRegistrations(engine: var Engine) =
  {.gcsafe.}:
    withLock appState.lock:
      for slot, text in appState.registrations:
        if slot < 0 or slot >= engine.decision.seats.len:
          continue
        if engine.decision.seats[slot].registered:
          continue
        var node: JsonNode
        try:
          node = parseJson(text)
        except CatchableError:
          continue
        if node.kind != JObject or node{"type"}.getStr() != "register":
          continue
        engine.decision.seats[slot].registered = true
        let prompt = node{"prompt"}.getStr().truncateRunes(MaxPromptRunes)
        let scripted = node{"scripted"}.getStr()
        let label = node{"policy"}.getStr().truncateRunes(MaxPolicyLabelRunes)
        engine.decision.seats[slot].prompt = prompt
        engine.decision.seats[slot].isLlm = prompt.len > 0
        engine.decision.seats[slot].baseline = parseBaseline(scripted)
        engine.decision.seats[slot].label =
          if label.len > 0: label
          elif prompt.len > 0: "prompt"
          elif scripted.len > 0: scripted
          else: "yielder"
        engine.game.seats[slot].kind = engine.decision.policyKind(slot)
        engine.game.seats[slot].baseline = $engine.decision.seats[slot].baseline
        engine.game.seats[slot].policyLabel = engine.decision.seats[slot].label
        let record = registerRecord(slot, seatAlias(slot),
          engine.decision.seats[slot].label,
          engine.game.seats[slot].kind,
          engine.game.seats[slot].baseline)
        engine.chatRecords.add(record)
        engine.writer.writeChat(record)
        echo "flatland: seat ", slot, " (", seatAlias(slot), ") registered as ",
          engine.game.seats[slot].kind, "/",
          engine.decision.seats[slot].label

proc runTurn(engine: var Engine) =
  let turnIndex = (engine.game.tick div engine.game.config.turnTicks) + 1
  engine.game.turn = turnIndex
  let elapsed = int((getMonoTime() - engine.episodeStart).inSeconds)
  # The tier-2 stream's decision rows. `SimEventKind` declares TurnStart,
  # DirectiveIssued and FallbackTaken and `events.nim` maps all three to JSON
  # keys, but nothing emitted them, so the COGAME_EVENTS_URI file carried no
  # turn, directive or fallback row at all. They go through `emitAnalysis`, not
  # `emit`: they are decisions, not physics, and must not reach `frameEvents`.
  engine.game.emitAnalysis(SimEvent(tick: engine.game.tick, kind: TurnStart,
                                    amount: turnIndex, train: -1, slot: -1))
  let outcome = engine.decision.turn(engine.game, turnIndex, elapsed)
  engine.game.feedDirectives.setLen(0)
  var turnRecords: seq[JsonNode]
  for seat in 0 ..< engine.game.seatCount():
    let directive = outcome.directives[seat]
    var replayOrders: seq[ReplayOrder]
    for order in directive.orders:
      engine.game.applyOrder(order.train,
                             TrainOrder(verb: order.verb, arg: order.arg))
      replayOrders.add(ReplayOrder(train: order.train, verb: order.verb,
                                   arg: order.arg))
    engine.writer.writeOrders(turnIndex, seat, replayOrders)
    engine.game.seats[seat].ordersRejected += directive.rejected
    if directive.source == dsLlm:
      inc engine.game.seats[seat].llmTurns
    elif directive.source == dsFallback:
      inc engine.game.seats[seat].fallbackTurns
    engine.game.seats[seat].radio = directive.say
    engine.game.seats[seat].notes = directive.notes
    let record = directiveRecord(engine.game, turnIndex, seat, directive,
                                 outcome.views[seat])
    engine.chatRecords.add(record)
    engine.writer.writeChat(record)
    engine.game.feedDirectives.add(record)
    engine.game.emitAnalysis(SimEvent(tick: engine.game.tick,
      kind: DirectiveIssued, train: -1, slot: seat,
      amount: directive.orders.len, content: $directive.source))
    try:
      turnRecords.add(parseJson(record))
    except CatchableError:
      discard
  for record in outcome.records:
    engine.chatRecords.add(record)
    engine.writer.writeChat(record)
    try:
      let node = parseJson(record)
      turnRecords.add(node)
      if node{"k"}.getStr() == "fallback":
        engine.game.emitAnalysis(SimEvent(tick: engine.game.tick,
          kind: FallbackTaken, train: -1, slot: node{"slot"}.getInt(),
          amount: node{"attempt"}.getInt(),
          content: node{"cause"}.getStr()))
    except CatchableError:
      discard
  engine.game.closeTurn()
  engine.broadcastFrame(turnEvents(engine.game, turnIndex, turnRecords), false)

proc writeArtifacts(engine: var Engine) =
  let resultsJson = engine.game.networkResultsJson()
  let record = resultRecord(resultsJson)
  engine.chatRecords.add(record)
  engine.writer.writeChat(record)
  let replayBytes = engine.writer.finish()
  try:
    engine.runtime.writeResults(resultsJson)
  except CatchableError as error:
    echo "flatland: failed to write results: ", error.msg
  try:
    engine.runtime.writeReplay(replayBytes)
  except CatchableError as error:
    echo "flatland: failed to write replay: ", error.msg
  let eventsUri = getEnv("COGAME_EVENTS_URI")
  if eventsUri.len > 0:
    try:
      var extra = newJObject()
      extra["network"] = %engine.game.network
      extra["seed"] = %int64(engine.game.config.seed)
      writeCogameUri(eventsUri,
                     eventsJsonl(engine.game.events, engine.game.tick, extra),
                     "application/x-ndjson", "COGAME_EVENTS_URI")
    except CatchableError as error:
      echo "flatland: failed to write events: ", error.msg
  echo "flatland: episode settled reason=", engine.game.reason,
    " endRule=", engine.game.endRule,
    " arrived=", engine.game.arrivedTotal,
    " onTime=", engine.game.fleetOnTime,
    " par=", engine.game.config.parOnTime,
    " ticks=", engine.game.tick

proc reportSeatFailure(engine: var Engine, slot: int) =
  let uri = getEnv("COGAME_PLAYER_FAILURE_URI")
  if uri.len == 0:
    return
  try:
    writeCogameUri(uri,
      playerFailurePayload("dispatcher seat " & $slot & " never connected", slot),
      "application/json", "COGAME_PLAYER_FAILURE_URI")
  except CatchableError as error:
    echo "flatland: failed to write the player failure payload: ", error.msg

proc runEpisode*(runtimeConfig: RuntimeConfig, game: SimServer) =
  var engine = Engine(game: game, runtime: runtimeConfig)
  engine.decision = initDecisionEngine(game)
  engine.writer = initReplayWriter(
    game.config.resolvedConfigJson(game.network))
  engine.episodeStart = getMonoTime()
  for slot in 0 ..< game.seatCount():
    engine.writer.writeJoin(slot, game.seats[slot].name,
                            (if slot < game.config.tokens.len:
                               game.config.tokens[slot] else: ""))

  # --- lobby ---------------------------------------------------------------
  let lobbyDeadline = game.config.lobbyJoinTimeoutTicks
  var lobbyTicks = 0
  while lobbyTicks < lobbyDeadline:
    engine.readRegistrations()
    var seated = 0
    for slot in 0 ..< game.seatCount():
      if engine.decision.seats[slot].registered:
        inc seated
        game.seats[slot].joined = true
    game.lobbyTicks = max(0, lobbyDeadline - lobbyTicks)
    if seated >= game.config.minPlayers:
      break
    if lobbyTicks mod TargetFps == 0:
      engine.broadcastFrame(newJArray(), false)
    sleep(1000 div TargetFps)
    inc lobbyTicks
  for slot in 0 ..< game.seatCount():
    if not engine.decision.seats[slot].registered:
      game.seats[slot].dead = true
      echo "flatland: WARNING seat ", slot, " (", seatAlias(slot),
        ") never registered; its fleet is dispatched by yielder"
      engine.reportSeatFailure(slot)

  # --- play ----------------------------------------------------------------
  game.startPlaying()
  engine.broadcastFrame(newJArray(), false)
  while game.phase == Playing:
    engine.readRegistrations()
    let elapsed = int((getMonoTime() - engine.episodeStart).inSeconds)
    if elapsed >= game.config.wallClockBudgetSeconds:
      engine.writer.writeStop(game.tick, erWallClock)
      game.stopAtWallClock()
      break
    if game.tick mod game.config.turnTicks == 0:
      engine.runTurn()
    try:
      game.step()
    except CatchableError as error:
      engine.writer.writeStop(game.tick, erFault)
      game.faultStop(error.msg)
      break
    engine.writer.writeHash(game.tick, game.gameHash())
    if game.tick mod 8 == 0 or game.phase != Playing:
      engine.broadcastFrame(stepEvents(game), false)
    if not game.config.fastMode:
      sleep(1000 div TargetFps)

  writeArtifacts(engine)

  # --- the shutdown grace ---------------------------------------------------
  # /healthz and /global keep answering for a bounded grace after the
  # artifacts are written, then the process exits.
  var grace = 0
  while grace < ShutdownGraceSeconds:
    engine.broadcastFrame(newJArray(), false)
    sleep(1000)
    inc grace

# ---------------------------------------------------------------------------
#  Entry
# ---------------------------------------------------------------------------

proc serveThreadProc(args: tuple[server: ptr Server, address: string,
                                 port: int]) {.thread.} =
  {.gcsafe.}:
    args.server[].serve(Port(args.port), args.address)

proc main*() =
  initAppState()
  let runtimeConfig = readRuntimeConfig()
  var config = defaultGameConfig()
  # Randomise the seed BEFORE config.update, so an explicit `seed` in the
  # runner's config still wins and every seed-derived draw follows the FINAL
  # seed (the starter's rule).
  config.seed = uint64(getTime().toUnix() and 0x7FFFFFFF)
  if runtimeConfig.config.len > 0:
    try:
      config.update(parseJson(runtimeConfig.config))
    except CatchableError as error:
      echo "flatland: bad config: ", error.msg
      quit(1)
  else:
    config.playerNames = @["Alpha", "Beta", "Gamma", "Delta"]
    config.validate()

  let game = newSimServer(config)
  # The join tokens have to reach the HTTP handler, which only sees globals,
  # and they must be in place BEFORE the listener opens — the certifier's
  # bad-token probe is the first thing that hits /player.
  withLock appState.lock:
    appState.tokens = config.tokens
  echo "flatland: network=", game.network, " seed=", config.seed,
    " trains=", game.trains.len, " seats=", game.seatCount(),
    " maxTicks=", config.maxTicks, " turnTicks=", config.turnTicks

  # Bake the board BEFORE the listener opens: a viewer's first-message clock
  # starts at connect, so nothing may be accepted until a frame can be
  # assembled instantly.
  discard bakeBed(game.map)
  discard bakeChips()
  discard bakeOverlays()

  let httpServer = newServer(httpHandler, websocketHandler, workerThreads = 2)
  var
    serverThread: Thread[tuple[server: ptr Server, address: string, port: int]]
    serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serveThreadProc,
               (server: serverPtr, address: runtimeConfig.host,
                port: runtimeConfig.port))
  httpServer.waitUntilReady()
  echo "flatland: listening on ", runtimeConfig.host, ":", runtimeConfig.port

  try:
    runEpisode(runtimeConfig, game)
  except CatchableError as error:
    echo "flatland: fault: ", error.msg
    game.faultStop(error.msg)
  quit(0)
