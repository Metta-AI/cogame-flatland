## The decision layer: the per-turn loop that asks all four dispatchers what
## their fleets do next, and ALWAYS has an answer.
##
## Cadence: one turn every `turnTicks` (16 ticks), 31 turns per episode. At
## each turn the server builds ALL FOUR seats' request bodies and issues them
## as ONE parallel batch — this is a simultaneous-decision game, so querying
## seats one after another would quadruple the wall clock for nothing.
##
## DEGRADE, NEVER HANG. Every wait here is bounded: attempt 1 gets
## `attempt1Ms`, the single retry gets `retryMs`, the whole turn is wrapped in
## a monotonic `turnBudgetMs` deadline, a rolling 60 s request counter is the
## rate guard, and the budget guard switches the LLM off entirely the moment
## two more full turns would not fit inside the engine's wall-clock stop. On a
## second failure the seat plays the `yielder` scripted orders for that turn —
## the SAME proc the `yielder` baseline uses, imported, never duplicated — and
## a `fallback` record names the cause.

import std/[json, monotimes, os, strutils, times]

import curly

import sim, directives, baselines, llm

type
  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field —
    ## or never registers at all — is `yielder`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    seats*: seq[SeatPolicy]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool                ## the budget guard fired; scripted from here on
    requestTimes*: seq[MonoTime] ## the rolling 60 s window, for the rate guard
    records*: seq[string]        ## chat records queued for the replay writer
    params*: BaselineParams

const
  RateWindowSeconds* = 60
  RateWindowCap* = 28
    ## `turnSpacingMs` pins the steady state at 20 req/min, but a turn in which
    ## every seat retries issues 8. The rolling counter keeps the episode under
    ## the sidecar's 30 req/min per-episode cap without ever sleeping on the
    ## critical path (the raid round 2 sidecar-throttle scar).

proc initDecisionEngine*(game: SimServer): DecisionEngine =
  result.client = newLlmClient(game.config)
  result.seats = newSeq[SeatPolicy](game.seatCount())
  result.params = DefaultBaselineParams
  for i in 0 ..< result.seats.len:
    result.seats[i].baseline = blYielder
    result.seats[i].label = "yielder"

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < engine.seats.len and engine.seats[seat].isLlm:
    "llm"
  else:
    "scripted"

proc contextFor*(game: SimServer, seat: int): OrderContext =
  result.map = game.map
  result.cap = game.config.trainsPerSeat
  for i in game.seatTrains(seat):
    result.trainIds.add(trainId(i))
    result.trainIndex.add(i)
    result.arrived.add(game.trains[i].state == tsArrived)
    result.previous.add(game.trains[i].order)

proc worldFor*(engine: DecisionEngine, game: SimServer): BaselineWorld =
  BaselineWorld(map: game.map, trains: game.trains, occ: game.occ,
                waitsFor: game.waitsFor, tick: game.tick, params: engine.params)

proc yielderFor*(engine: DecisionEngine, game: SimServer, seat: int): Directive =
  ## THE fallback. It is the `yielder` baseline proc, not a copy of its rules.
  yielderDirective(engine.worldFor(game), game.contextFor(seat))

# ---------------------------------------------------------------------------
#  Records
# ---------------------------------------------------------------------------

proc fallbackRecord(turn, seat, attempt: int, cause, detail: string): string =
  $(%*{
    "k": "fallback", "turn": turn, "slot": seat, "attempt": attempt,
    "cause": cause, "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc registerRecord*(seat: int, alias, policy, kind, baseline: string): string =
  ## The REDACTED registration record. The seat's prompt is NEVER written:
  ## only the policy label, the kind, and which baseline a scripted seat picked.
  $(%*{
    "k": "register", "slot": seat, "alias": alias,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind, "baseline": baseline
  })

proc directiveRecord*(game: SimServer, turn, seat: int, directive: Directive,
                      view: JsonNode): string =
  var ids: seq[string]
  for i in game.seatTrains(seat):
    ids.add(trainId(i))
  $(%*{
    "k": "directive", "turn": turn, "slot": seat, "alias": seatAlias(seat),
    "source": $directive.source, "latency_ms": directive.latencyMs,
    "orders": directive.serialise(ids),
    "say": directive.say.truncateRunes(MaxSayRunes),
    "view": view
  })

proc budgetGuardRecord(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

proc resultRecord*(resultsJson: string): string =
  ## The `result` control record — the whole results document, written once
  ## into the replay chat stream at episode end. It is what makes the replay
  ## SELF-SUFFICIENT: without it the outcome exists only at
  ## COGAME_RESULTS_URI, and `replay_summary.py`'s `results` reads `{}` for a
  ## spectator holding the bytes.
  "{\"k\":\"result\",\"results\":" & resultsJson & "}"

# ---------------------------------------------------------------------------
#  The rate guard
# ---------------------------------------------------------------------------

proc pruneRateWindow(engine: var DecisionEngine, now: MonoTime) =
  var kept: seq[MonoTime]
  for stamp in engine.requestTimes:
    if (now - stamp).inSeconds < RateWindowSeconds:
      kept.add(stamp)
  engine.requestTimes = kept

proc rateBudget(engine: var DecisionEngine, now: MonoTime): int =
  engine.pruneRateWindow(now)
  max(0, RateWindowCap - engine.requestTimes.len)

# ---------------------------------------------------------------------------
#  The turn
# ---------------------------------------------------------------------------

proc turn*(engine: var DecisionEngine, game: SimServer, turnIndex: int,
           elapsedSeconds: int): tuple[records: seq[string],
                                       directives: seq[Directive],
                                       views: seq[JsonNode]] =
  ## Runs ONE decision turn and returns each seat's directive plus the replay
  ## chat records it produced. NEVER raises: every failure path ends in a
  ## legal directive.
  let
    turns = game.config.turnsPerEpisode()
    budget = initDuration(milliseconds = max(1, game.config.turnBudgetMs))
    turnStart = getMonoTime()
  engine.client.throttled = false
  result.directives = newSeq[Directive](game.seatCount())
  result.views = newSeq[JsonNode](game.seatCount())
  for seat in 0 ..< game.seatCount():
    result.views[seat] = game.seatObservation(seat, turnIndex, turns)

  # --- budget guard: settle EARLY rather than overrun -----------------------
  if not engine.llmOff:
    let turnSeconds = (game.config.turnBudgetMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > game.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.records.add(budgetGuardRecord(turnIndex,
        max(0, game.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "flatland: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  # --- which seats need a call? --------------------------------------------
  var open: seq[int]
  for seat in 0 ..< game.seatCount():
    if engine.seats[seat].isLlm and not engine.llmOff and
        not engine.client.disabled:
      open.add(seat)
    elif engine.seats[seat].isLlm:
      ## An LLM seat that CANNOT call the LLM this turn is a FALLBACK, not a
      ## scripted policy, and the cause enum names both reasons it happens.
      var directive = engine.yielderFor(game, seat)
      directive.source = dsFallback
      result.directives[seat] = directive
      let cause = if engine.llmOff: "budget_guard" else: "no_credentials"
      result.records.add(fallbackRecord(turnIndex, seat, 1, cause,
        "the LLM is unavailable for this turn; playing yielder"))
      echo "flatland llm: seat ", seat, " falling back to yielder (", cause,
        ") on turn ", turnIndex
    else:
      var directive = scriptedDirective(engine.worldFor(game),
                                        engine.seats[seat].baseline,
                                        game.contextFor(seat))
      directive.source = dsScripted
      result.directives[seat] = directive

  # --- the rate guard -------------------------------------------------------
  if open.len > 0:
    let allowed = engine.rateBudget(getMonoTime())
    if open.len > allowed:
      var kept: seq[int]
      for i, seat in open:
        if i < allowed:
          kept.add(seat)
          continue
        var directive = engine.yielderFor(game, seat)
        directive.source = dsFallback
        result.directives[seat] = directive
        result.records.add(fallbackRecord(turnIndex, seat, 1, "rate_guard",
          "the trailing 60 s request window is full"))
        echo "flatland llm: seat ", seat, " falling back to yielder ",
          "(rate_guard) on turn ", turnIndex
      open = kept

  # --- the rate floor -------------------------------------------------------
  if open.len > 0 and engine.batchStarted and game.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < game.config.turnSpacingMs:
      sleep(min(game.config.turnSpacingMs, game.config.turnSpacingMs - since))
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true

  # --- up to two PARALLEL batches ------------------------------------------
  var attempt = 0
  while open.len > 0 and attempt < 2:
    if engine.client.disabled:
      break
    if getMonoTime() - turnStart >= budget:
      for seat in open:
        result.records.add(fallbackRecord(turnIndex, seat, attempt + 1,
          "timeout", "per-turn budget exhausted before attempt " & $(attempt + 1)))
      break
    let deadlineMs =
      if attempt == 0: game.config.attempt1Ms else: game.config.retryMs
    var batch: RequestBatch
    for seat in open:
      var user = $result.views[seat]
      if attempt > 0:
        user.add("\n\nYour previous reply was not usable. Reply with ONLY " &
          "the JSON object described above, starting with '{'.")
      let request = engine.client.requestFor(
        SystemPrompt, userMessage(engine.seats[seat].prompt, user))
      batch.post(request.url, request.headers, request.body, $seat)
      engine.requestTimes.add(getMonoTime())
    let started = getMonoTime()
    # curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    # SECONDS, so this conversion FLOORS — sim_config rejects a sub-second
    # value, which makes the floor an identity (9000 -> 9 s, 4000 -> 4 s).
    let responses = engine.client.curl.makeRequests(batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var stillOpen: seq[int]
    for position, seat in open:
      var cause = "parse_error"
      try:
        let text = engine.client.textOf(responses[position].response,
                                        responses[position].error,
                                        batch[position].url)
        var directive = parseDirective(extractJsonObject(text),
                                       game.contextFor(seat))
        directive.source = dsLlm
        directive.latencyMs = latency
        result.directives[seat] = directive
      except CatchableError as error:
        if responses[position].error.len > 0:
          cause = (if "timeout" in responses[position].error.toLowerAscii():
                     "timeout" else: "transport_error")
        elif error.msg.startsWith("llm throttled"):
          cause = "timeout"
        result.records.add(fallbackRecord(turnIndex, seat, attempt + 1, cause,
                                          error.msg))
        echo "flatland llm: seat ", seat, " attempt ", attempt + 1,
          " failed, falling back if it fails again: ", error.msg
        stillOpen.add(seat)
    open = stillOpen
    inc attempt
    if engine.client.throttled and open.len > 0:
      ## FAIL FAST: the only model left answered 429, so the retry batch would
      ## be refused the same way. Spend the rest of the turn on the scripted
      ## layer instead of on a call that cannot land.
      echo "flatland llm: provider throttled with no other candidate; ",
        open.len, " seat(s) fall back for turn ", turnIndex
      break

  # --- anything still open plays yielder for this turn ---------------------
  for seat in open:
    var directive = engine.yielderFor(game, seat)
    directive.source = dsFallback
    result.directives[seat] = directive
    let cause =
      if engine.client.disabled or engine.client.transport == ltNone:
        "no_credentials"
      elif engine.llmOff: "budget_guard"
      else: "parse_error"
    result.records.add(fallbackRecord(turnIndex, seat, 2, cause,
      "seat fell back to the yielder orders"))
    ## "falling back" is the phrase phase 60 greps the GAME log for.
    echo "flatland llm: seat ", seat, " falling back to yielder (", cause,
      ") on turn ", turnIndex
