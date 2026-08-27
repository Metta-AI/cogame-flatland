## Claude-backed dispatching. A policy is just a prompt: the game server
## composes the seat's observation plus that seat's PLAYER_PROMPT and asks
## Claude what its six trains do for the next 16 ticks.
##
## Forked from `coworld-ctf`'s `src/ctf/llm.nim` with NO behaviour change — the
## credential ladder, the Bedrock model rotation, the fence-tolerant JSON
## extraction and the rune-boundary truncation are all that file's, because
## they are all scar tissue from real hosted failures.
##
## Flatland is a SIMULTANEOUS-decision game, so ALL FOUR seats' calls go out as
## ONE parallel batch per turn (`curly.makeRequests`). Seats are never queried
## sequentially: that is what keeps 31 turns inside the wall-clock budget.
##
## Credentials, in order of preference:
##   Bedrock sidecar (AWS_ENDPOINT_URL_BEDROCK_RUNTIME + AWS_BEARER_TOKEN_BEDROCK)
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself and every turn falls back to
## the scripted layer INSTANTLY, with no network wait — which is what lets
## offline certification finish in seconds.

import std/[json, os, strutils]

import bitworld/runtime
import curly

import sim_types, sim_config

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool
      ## The provider answered 429 and there is no other candidate model to
      ## rotate to. Set per turn, cleared by the turn loop: retrying inside
      ## the same turn cannot succeed, so the seat fails fast to the scripted
      ## fallback instead of spending the turn budget on a refused call.

  LlmError* = object of ValueError

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "flatland llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order; BEDROCK_MODEL pins
  ## one. `us.anthropic.claude-sonnet-4-6` is deliberately NOT a candidate: it
  ## times out on every sidecar call (cogame-raid round 2, 2026-08-23), and one
  ## haiku throttle cascading into a sonnet retry burns the whole turn.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "flatland llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: (if config.model.len > 0: config.model
            else: "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1, config.maxOutputTokens)
  )
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "flatland llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "flatland llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    ## The exact phrase phase 60 greps the GAME log for, alongside "falling
    ## back" in decide.nim: "LLM provider is unavailable".
    echo "flatland llm: no credentials — the LLM provider is unavailable; ",
      "every turn is falling back to the scripted layer"

proc requestFor*(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live.
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf*(client: LlmClient, response: Response, error, url: string): string =
  ## The text of one batched reply, or an LlmError describing why there is
  ## none. Auth failure disables the client for the rest of the episode;
  ## model-access denial and throttling rotate the Bedrock model instead.
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    ## RUNE-safe: this text becomes `fallback.detail` in the replay, and a
    ## provider body is arbitrary bytes. A byte slice can cut a codepoint in
    ## half, and truncateRunes downstream only SHORTENS — it cannot repair one.
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LlmError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(LlmError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if not client.tryNextBedrockModel("throttled"):
      client.throttled = true
    raise newException(LlmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "anthropic error " & $response.code & ": " &
      response.body.truncateRunes(MaxFallbackDetailRunes))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if result.len > MaxReplyBytes:
    ## The cap is on the BYTES read from the provider before parsing.
    result = result[0 ..< MaxReplyBytes]
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "reply cut off at max_tokens before any " &
      "JSON: " & result.truncateRunes(160).replace("\n", " "))

const SystemPrompt* = """
You are the dispatcher for SIX trains on a shared rail network. Three other dispatchers
run six trains each on the same rails. You do not control theirs and you cannot see
their targets or their orders. Every 16 simulation ticks you issue orders and a
deterministic driver runs every train until you change them.

THE NETWORK
- A grid of track: straights, curves, three-way switches, one flat crossing, eight
  stations A-H (three platforms each), six passing sidings S1-S6, nine named junctions
  J1-J9. Between two junctions the track is a SECTION and only one train fits per cell,
  so no train can overtake inside a section.
- Two trains may not enter the same section from opposite ends. The second one waits at
  the mouth - and while it waits it is standing ON the junction, blocking everyone
  behind it. That is how a network jams.
- Trains break down at random for 8 to 24 ticks. A broken train blocks its cell and
  nobody can repair it. Plan around it.
- Speed class is ticks_per_cell: 1 is an express, 4 is a freight. A freight on the main
  line behind an express is a whole timetable lost.

WHAT SCORES
Only how many of the TWENTY-FOUR trains reach their target station ON TIME. Everyone
gets the same number. Your own six are a tie-break worth almost nothing. Getting one of
your trains through by stalling two of somebody else's is a loss.

YOUR ORDERS (one per train per turn; a train keeps its order until you change it)
- {"train":"T13","verb":"run"}                 head for the target on the fast route
- {"train":"T13","verb":"route","via":"S3"}    head for the target THROUGH that point
- {"train":"T13","verb":"siding","at":"S3"}    pull into that siding and wait there
- {"train":"T13","verb":"hold"}                stop where it is (or do not depart yet)

A DEADLOCK IS PERMANENT
Trains cannot reverse. If your train is nose-to-nose with another across a section,
neither will ever move again and both are lost for the rest of the episode. The only
cure is prevention: side a train BEFORE it commits, or hold it before it departs.

TALKING
"say" is a radio call every other dispatcher hears next turn. It is the ONLY way they
learn what you intend. Use it to claim a section, to name which way you are running a
single-track, or to ask someone to side a train. "notes" comes back to you next turn and
to nobody else.

REPLY FORMAT
Reply with ONE JSON object and NOTHING else. Your reply MUST begin with the character {
and end with }. No prose, no markdown, no code fences.
{"orders":[{"train":"T13","verb":"siding","at":"S3"}],"say":"<=120 chars","notes":"<=240 chars"}
"""

proc operatorBlock*(prompt: string): string =
  ## The seat's own PLAYER_PROMPT, under a heading that says how much weight it
  ## carries. Never echoed into the replay or the results.
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" &
    prompt.truncateRunes(MaxPromptRunes) & "\n\n"

proc networkBlock*(briefing: string): string =
  ## The whole network — the ASCII tile grid, the station platform cells, the
  ## siding and junction cells and the junction graph — at the head of the user
  ## message. STATIC for the episode, but re-sent every turn: a Messages-API
  ## request carries no history, so a seat told the topology only at
  ## registration would never see it again (design note §Decisions, "Visible:
  ## the whole network, once, at registration").
  if briefing.len == 0:
    return ""
  "THE NETWORK (static for the whole episode; name every point by the ids " &
    "in it):\n" & briefing & "\n\n"

proc userMessage*(networkBriefing, operatorPrompt, viewJson: string): string =
  ## The user message: the static network, the operator's guidance, then the
  ## seat's observation. Built server-side (see decide.nim).
  networkBlock(networkBriefing) & operatorBlock(operatorPrompt) & viewJson
