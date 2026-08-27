# Protocol

## The Coworld contract

Inherited from `coworld-ctf` unchanged in shape.

| Direction | Variable | Meaning |
|---|---|---|
| in | `COGAME_CONFIG_URI` | the resolved `game_config` JSON |
| in | `COGAME_HOST` / `COGAME_PORT` | bind address |
| in | `COGAME_LOAD_REPLAY_URI` | local replay mode |
| out | `COGAME_RESULTS_URI` | `results.json` |
| out | `COGAME_SAVE_REPLAY_URI` | the binary `COWLDFLT` replay |
| out | `COGAME_PLAYER_FAILURE_URI` | the platform's CLOSED payload, exactly `{"message", "failed_policy_index"}` |
| out | `COGAME_EVENTS_URI` | the tier-2 JSON-lines analysis stream |

Player sockets are at `/player?slot=<i>&token=<t>`.

**Routes the certifier probes before any player pod starts**, all registered ahead of
any catch-all and none of which opens a player socket:

* `GET /healthz`
* `GET /client/player?slot=&token=` — token-checked, serves a real page
* `GET /client/global` — the broadcast page
* the `/global` websocket's first message

All four keep answering for a bounded grace after the artifacts are written, then the
process exits 0. Global broadcasts are fire-and-forget, so a slow viewer can never stall
the episode.

## Registration

The player container sends ONE Sprite v1 chat message:

```json
{"policy": "<label>", "prompt": "<PLAYER_PROMPT or empty>", "scripted": "timetable"|"yielder"|null}
```

`prompt` is rune-truncated at 4000 and `policy` at 64. It is **re-sent** for the first
~10 s of received frames, because joins are slot-sequential and the first registration
can land while the seat has no index yet; the server HOLDS an unappliable registration
and re-reads it when the slot lands. Registering twice is harmless.

The server consumes a registration message as REGISTRATION — it is never applied
in-world and never written to the replay chat stream. A redacted `register` record is
written instead (policy label and kind, **never the prompt**). Any other chat text from a
seat is dropped: dispatchers speak through `say`.

The player then only acknowledges frames, and **exits 0 on a dead socket**: whisky's
`receiveMessage` raises on a close frame and mummy's `send` only queues, so the game's
own `quit(0)` can outrun the flushed frame.

## Where the LLM call happens

**In the game server, not the player container.** The `anthropic_api_key` coworld secret
is injected into the GAME pod
(`game.runnable.env.ANTHROPIC_API_KEY_URI = secret://coworld/flatland/anthropic_api_key`),
phase 60 greps the GAME log for `falling back` / `LLM provider is unavailable`, and
`docker_smoke.sh` forwards `ANTHROPIC_API_KEY` to the game container only. No
`USE_BEDROCK` flag is needed on the policies, because the player pod makes no LLM call.

All four seats' requests go out as ONE parallel batch per turn (`curly.makeRequests`):
this is a simultaneous-decision game, and serial calls would quadruple the wall clock.

## Wall-clock arithmetic

```
attempt1Ms                          9.0 s
retryMs                             4.0 s
turnBudgetMs                       14.0 s   (monotonic deadline around the whole turn)
turnSpacingMs                      12.0 s   -> 4 seats x 60/12 = 20 req/min (cap 30)

31 turns x max(spacing 12 s, budget 14 s), absolute worst          = 434 s
   typical (haiku answers in ~3-5 s, so spacing dominates)         = 372 s
496 ticks, 24 trains, integer Nim + BFS, fastMode                  =   1 s
lobby / connect wait (cap 100 s; typical 15 s)                     =  15 s
results + replay write + the shutdown grace                        =  20 s
                                                                   -------
typical total                                                      = 408 s   < 720 s
absolute worst case                                                = 555 s   < 660 s
engine hard stop wallClockBudgetSeconds                            = 660 s   -> "deadline"
platform kill (episodeTimeoutSeconds)                              = 1200 s
```

720 s is 60 % of the assumed 1200 s `episodeTimeoutSeconds`; every shipped variant's
`wallClockBudgetSeconds` is <= 660 and `tests/test_flatland_manifest.nim` asserts it.

A **rate guard** keeps a rolling 60 s request counter: if issuing the next batch would
push the trailing count above 28, the seats that would exceed it skip the call and take
the `yielder` orders with `cause = "rate_guard"`. Bounded, logged, never a sleep on the
critical path.

## The replay

Binary `COWLDFLT`. The bytes are SELF-SUFFICIENT: no server is contacted except S3 for
the file.

| Content | Carries |
|---|---|
| header | magic `COWLDFLT`, format version, game name `flatland`, gameVersion |
| config JSON | `seed`, `network`, `num_agents`, `trainsPerSeat`, `maxTicks`, `turnTicks`, `parOnTime`, `slackTicks`, `malfunctionRate`, `minDuration`, `maxDuration`, `jamTicks`, `deadlockTicks`, `quiesceTicks`, `players[].name`, `slots[]`, `fastMode` |
| joins | per seat: real policy name, slot, token |
| orders | per turn, per seat, per train — this game's entire input log |
| chats | `register` / `directive` / `fallback` / `budget_guard` / `stop` / `result` |
| hashes | one `gameHash` per tick — the integrity chain the viewer checks |

The `.rail` map files are compiled into the binary AND into the wasm module, and the
replay carries the map NAME, so the viewer reconstructs the exact network with no fetch.
A map file change is a GameVersion bump.

**The wall-clock stop is a load-bearing record, not an inference.** A wall-clock fact
cannot be re-derived from sim state, so it is written as one record applied by the SAME
proc on record and on playback, and the record -> re-derive test runs for EVERY end
reason, not just the healthy one.

### Chat records

| `k` | Fields |
|---|---|
| `register` | `slot`, `alias`, `policy` (<= 64 runes), `kind`, `baseline` |
| `directive` | `turn`, `slot`, `alias`, `source` (`llm`\|`scripted`\|`fallback`), `latency_ms`, `orders`, `say` (<= 120 runes), `view` |
| `fallback` | `turn`, `slot`, `attempt`, `cause`, `detail` (<= 200 runes) |
| `budget_guard` | `turn`, `remaining_s` |
| `stop` | `tick`, `endRule` |
| `result` | the full results document |

`fallback.cause` is one of
`timeout | parse_error | transport_error | no_credentials | rate_guard | budget_guard | disconnected`.

### Derived broadcast events

`stepEvents` derives these from state deltas during playback, so they cost no replay
bytes and are identical live and in replay. A CLOSED enum of thirteen kinds:

`turn` `order` `say` `fallback` `depart` `arrive` `malfunction` `repaired` `jam`
`jamclear` `deadlock` `deadlockclear` `end`

**Scrubber beats** — the only kinds the appended game block places: `arrival`,
`malfunction`, `deadlock`, `fallback`, `end`.

### Forensics without Nim or Docker

```bash
curl -sSL "$replay_url" -o /tmp/ep.replay
python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
jq -e . /tmp/ep.json >/dev/null                       # strict UTF-8 JSON: ok
jq -r '.protocol, .results.reason, .results.fleetOnTime, .results.arrivedTotal' /tmp/ep.json
jq -r '[.orders[]|select(.source=="llm")]|length, .fallbacks, (.radio|length)' /tmp/ep.json
```

Python 3 stdlib only. CI's `docker-smoke` job therefore sets
`SMOKE_REQUIRE_REPLAY_JSON=0`, which the shared `tools/ci/docker_smoke.sh` supports by
design.

## The results document

A CLOSED schema. Adding a key means updating `roster.networkResultsJson`, the manifest's
`results_schema` and `docker_smoke.sh`'s expected-key set in the same commit.

```json
{
  "names":            ["daveey", "daveey-1", "Baseline (1)", "Baseline (2)"],
  "aliases":          ["Alpha", "Beta", "Gamma", "Delta"],
  "scores":           [16247, 16246, 16245, 16245],
  "win":              [true, true, true, true],
  "winner":           null,
  "reason":           "complete",
  "endRule":          "tickCap",
  "fleetOnTime":      16,
  "parOnTime":        15,
  "arrivedTotal":     24,
  "onTime":           [5, 4, 3, 4],
  "arrived":          [6, 6, 6, 6],
  "latenessTicks":    [12, 41, 96, 33],
  "stranded":         0,
  "deadlockedTrains": 0,
  "deadlocks":        1,
  "deadlockTicks":    31,
  "jams":             7,
  "jamTicks":         104,
  "longestJamTicks":  38,
  "malfunctions":     29,
  "malfunctionTicks": 441,
  "finalTick":        496,
  "turnsPlayed":      31,
  "seed":             1734029581,
  "network":          "main_b",
  "policyKinds":      ["llm", "llm", "scripted", "scripted"],
  "crossPlay":        true,
  "llmTurns":         [31, 30, 0, 0],
  "fallbackTurns":    [0, 1, 0, 0],
  "ordersRejected":   [0, 3, 0, 0],
  "deadSeats":        [false, false, false, false],
  "stopDetail":       ""
}
```

## The viewer

A **static wasm bundle, never a pod**. The manifest declares
`game.replay_viewer = {"bundle": "static-replay-viewer"}`; `tools/build_replay_viewer.sh`
compiles the SAME `src/flatland/sim.nim` to wasm through the pinned
`emscripten/emsdk:4.0.15` container and bundles it with the chrome. In the browser,
`flatland_load_replay` pre-scans the whole episode once (so the on-time sparkline and
the scrubber beats draw at full width on the first frame), then `flatland_frame`
re-steps the sim from the recorded orders and compares `gameHash` against the recorded
hash every tick. The shell sets `data-replay-loaded="true"` on `<html>` on the first
drawn frame and `data-replay-error="<message>"` on failure.
