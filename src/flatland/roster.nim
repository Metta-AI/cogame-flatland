## Joins, identities and the results document. Forked from `coworld-ctf`'s
## `src/ctf/roster.nim` with the two named edits of the design note:
##
## 1. **Aliases.** `seatAlias(slot)` (in `sim_types.nim`) returns
##    `IdentityNames[slot]` title-cased -> `Alpha`, `Beta`, `Gamma`, `Delta`.
##    The `IdentityNames` array itself is unchanged. `showPlayerLabels` is
##    false, so no in-board sprite can leak an identity.
## 2. **`squadResultsJson` -> `networkResultsJson`** — one entry per seat, four
##    entries in every seat-indexed array, keys exactly as docs/PROTOCOL.md
##    lists them. The schema is CLOSED: adding a key means updating this proc,
##    the manifest's `results_schema` and `tools/ci/docker_smoke.sh`'s expected
##    key set in the SAME commit.

import std/[json, strutils]

import sim

proc resolveSlot*(game: SimServer, requested: int, token: string): int =
  ## Slot resolution: an explicit `?slot=` wins when the token matches, else
  ## the next free seat. Returns -1 when the credentials do not check out.
  if requested >= 0 and requested < game.seatCount():
    if game.config.tokens.len > requested and
        game.config.tokens[requested].len > 0 and
        game.config.tokens[requested] != token:
      return -1
    return requested
  for slot in 0 ..< game.seatCount():
    if not game.seats[slot].joined:
      return slot
  -1

proc admit*(game: SimServer, slot: int, name, token: string) =
  if slot < 0 or slot >= game.seats.len:
    return
  game.seats[slot].joined = true
  game.seats[slot].token = token
  if name.len > 0:
    game.seats[slot].name = name

proc allSeated*(game: SimServer): bool =
  for slot in 0 ..< game.seatCount():
    if not game.seats[slot].joined:
      return false
  true

proc networkResultsJson*(game: SimServer): string =
  ## The closed results document. `winner` is always null: a cooperative
  ## episode has no winner, and `win[s]` is the same "did the network run"
  ## boolean for all four seats.
  var
    names = newJArray()
    aliases = newJArray()
    scores = newJArray()
    win = newJArray()
    onTime = newJArray()
    arrived = newJArray()
    lateness = newJArray()
    policyKinds = newJArray()
    llmTurns = newJArray()
    fallbackTurns = newJArray()
    ordersRejected = newJArray()
    deadSeats = newJArray()
  let networkWon = game.networkWin()
  var sawLlm = false
  var sawScripted = false
  for slot in 0 ..< game.seatCount():
    names.add(%game.seats[slot].name)
    aliases.add(%seatAlias(slot))
    scores.add(%game.scoreFor(slot))
    win.add(%networkWon)
    onTime.add(%game.onTime[slot])
    arrived.add(%game.arrived[slot])
    lateness.add(%game.latenessTicks[slot])
    policyKinds.add(%game.seats[slot].kind)
    llmTurns.add(%game.seats[slot].llmTurns)
    fallbackTurns.add(%game.seats[slot].fallbackTurns)
    ordersRejected.add(%game.seats[slot].ordersRejected)
    deadSeats.add(%game.seats[slot].dead)
    if game.seats[slot].kind == "llm": sawLlm = true
    else: sawScripted = true
  var deadlockedTrains = 0
  for train in game.trains:
    if train.stranded:
      inc deadlockedTrains
  $(%*{
    "names": names,
    "aliases": aliases,
    "scores": scores,
    "win": win,
    "winner": newJNull(),
    "reason": $game.reason,
    "endRule": $game.endRule,
    "fleetOnTime": game.fleetOnTime,
    "parOnTime": game.config.parOnTime,
    "arrivedTotal": game.arrivedTotal,
    "onTime": onTime,
    "arrived": arrived,
    "latenessTicks": lateness,
    "stranded": game.stranded,
    "deadlockedTrains": deadlockedTrains,
    "deadlocks": game.deadlocks,
    "deadlockTicks": game.deadlockTicks,
    "jams": game.jams,
    "jamTicks": game.jamTicks,
    "longestJamTicks": game.longestJamTicks,
    "malfunctions": game.malfunctions,
    "malfunctionTicks": game.malfunctionTicks,
    "finalTick": game.tick,
    "turnsPlayed": game.turn,
    "seed": int64(game.config.seed),
    "network": game.network,
    "policyKinds": policyKinds,
    "crossPlay": sawLlm and sawScripted,
    "llmTurns": llmTurns,
    "fallbackTurns": fallbackTurns,
    "ordersRejected": ordersRejected,
    "deadSeats": deadSeats,
    "stopDetail": game.stopDetail.truncateRunes(MaxFallbackDetailRunes)
  })

const ResultsKeys*: array[30, string] = [
  "names", "aliases", "scores", "win", "winner", "reason", "endRule",
  "fleetOnTime", "parOnTime", "arrivedTotal", "onTime", "arrived",
  "latenessTicks", "stranded", "deadlockedTrains", "deadlocks",
  "deadlockTicks", "jams", "jamTicks", "longestJamTicks", "malfunctions",
  "malfunctionTicks", "finalTick", "turnsPlayed", "seed", "network",
  "policyKinds", "crossPlay", "llmTurns", "fallbackTurns"
]

const ResultsKeysTail*: array[3, string] = [
  "ordersRejected", "deadSeats", "stopDetail"
]

proc allResultsKeys*(): seq[string] =
  for key in ResultsKeys:
    result.add(key)
  for key in ResultsKeysTail:
    result.add(key)

proc playerFailurePayload*(message: string, index: int): string =
  ## The platform's CLOSED payload — exactly `{"message", "failed_policy_index"}`,
  ## nothing else.
  $(%*{"message": message.truncateRunes(MaxFallbackDetailRunes),
       "failed_policy_index": index})
