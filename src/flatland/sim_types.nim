## Core wire types, caps and version pins for cogame-flatland.
##
## Forked from `coworld-ctf`'s `src/ctf/sim_types.nim`: the `GameVersion`
## discipline (prepend-only changelog comment, checked by
## `tools/ci/check_gameversion.sh`), `TargetFps`, and the RUNE caps every
## recorded string is truncated on. The caps `MaxSayRunes` and `MaxNoteRunes`
## are RE-PINNED for this fork (design note §Decisions -> reply schema): a
## dispatcher's radio call has to name a train, a section and an intent, which
## a 10-character in-world shout cannot do.
##
## RUNE DISCIPLINE. Every cap here is measured in RUNES (Unicode codepoints)
## and every truncation lands on a rune boundary. Slicing a string by BYTE
## index anywhere on the path to the replay is forbidden: a byte-truncated
## multi-byte character renders fine in a browser and then fails a strict
## UTF-8 parser.

import std/[strutils, unicode]

const
  ## GameVersion changelog — PREPEND new entries, never edit an old line.
  ##   1  first release: Flatland rules idiom on the coworld-ctf stack.
  GameVersion* = "1"

  ProtocolName* = "flatland/v1"
  GameName* = "flatland"

  TargetFps* = 24
    ## Sim ticks per wall-clock second in a paced (non-fastMode) run. The
    ## replay viewer plays back at this cadence.

  MaxSayRunes* = 120
    ## The network radio call, in RUNES. Re-pinned from the starter's
    ## `ShoutMaxChars = 10`: the shout mechanic is deleted (§Sim module) and
    ## this is a dispatcher's radio, which must name a train and a section.
  MaxNoteRunes* = 240
    ## The seat's private note, echoed back to it next turn. Re-pinned from
    ## the starter's 160.
  MaxPolicyLabelRunes* = 64   ## `register.policy` cap, in RUNES.
  MaxFallbackDetailRunes* = 200 ## `fallback.detail` / `stopDetail` cap.
  MaxPromptRunes* = 4000      ## PLAYER_PROMPT transport cap.
  MaxReplyBytes* = 4096       ## bytes read from the provider before parsing.
  MaxTrainIdRunes* = 4
  MaxVerbRunes* = 6
  MaxNodeIdRunes* = 4

  MaxTrains* = 32             ## sprite-pool bound; every variant is <= 24.
  MaxSeats* = 4
  GridWidth* = 28
  GridHeight* = 14
  MaxRailCells* = GridWidth * GridHeight

type
  FlatlandError* = object of CatchableError
    ## The one error type the sim raises; the server catches it and settles.

  Dir* = range[0 .. 3]
    ## N = 0, E = 1, S = 2, W = 3 (upstream's orientation enum, `upstream.nim`).

  TrainState* = enum
    tsWaiting = "waiting"
    tsRunning = "running"
    tsHeld = "held"
    tsMalfunctioning = "malfunctioning"
    tsArrived = "arrived"

  Action* = enum
    ## Upstream's five-action space, values pinned in `upstream.nim`.
    acDoNothing = 0
    acMoveLeft = 1
    acMoveForward = 2
    acMoveRight = 3
    acStop = 4

  OrderVerb* = enum
    ovRun = "run"
    ovHold = "hold"
    ovSiding = "siding"
    ovRoute = "route"

  OrderResult* = enum
    orRunning = "running"
    orArrived = "arrived"
    orHeld = "held"
    orParked = "parked"
    orNoRoute = "no_route"
    orNoSiding = "no_siding"
    orUnknownTrain = "unknown_train"
    orDeadlocked = "deadlocked"
    orMalfunction = "malfunction"

  TrainOrder* = object
    verb*: OrderVerb
    arg*: string   ## the siding id for `siding`, the via node id for `route`.

  GamePhase* = enum
    Lobby = "lobby"
    Playing = "playing"
    GameOver = "gameover"

  EndRule* = enum
    erAllArrived = "allArrived"
    erQuiescent = "quiescent"
    erTickCap = "tickCap"
    erWallClock = "wallClock"
    erFault = "fault"

  EndReason* = enum
    ## The starter's closed enum. Exactly these three values are legal.
    reComplete = "complete"
    reDeadline = "deadline"
    reFault = "fault"

const
  DirNames*: array[4, string] = ["N", "E", "S", "W"]
  ## The four seat aliases. These are the starter's `IdentityNames`
  ## (`src/ctf/roster.nim:64`), title-cased for display. They are the ONLY
  ## names that ever reach an observation, a prompt, an order or a sprite
  ## label; real policy names live spectator-side only.
  IdentityNames*: array[4, string] = ["alpha", "beta", "gamma", "delta"]

proc opposite*(d: Dir): Dir {.inline.} =
  Dir((int(d) + 2) mod 4)

proc leftOf*(d: Dir): Dir {.inline.} =
  Dir((int(d) + 3) mod 4)

proc rightOf*(d: Dir): Dir {.inline.} =
  Dir((int(d) + 1) mod 4)

proc dirName*(d: Dir): string {.inline.} =
  DirNames[int(d)]

proc parseDir*(text: string): Dir =
  for i, name in DirNames:
    if name == text:
      return Dir(i)
  Dir(0)

proc seatAlias*(slot: int): string =
  ## `Alpha` | `Beta` | `Gamma` | `Delta`. The in-game name space.
  if slot < 0 or slot >= IdentityNames.len:
    return "Seat" & $slot
  let name = IdentityNames[slot]
  toUpperAscii(name[0]) & name[1 .. ^1]

proc trainId*(index: int): string =
  ## `T01` .. `T24`. Ids are public; targets and orders are not.
  "T" & align($(index + 1), 2, '0')

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc sanitizeLine*(text: string, limit: int): string =
  ## One recorded free-text line: newlines collapse to spaces (one record is
  ## one line), control characters are dropped, then a RUNE-boundary cut.
  var flat = newStringOfCap(text.len)
  for rune in text.runes:
    let value = int(rune)
    if value == 10 or value == 13 or value == 9:
      flat.add(' ')
    elif value < 32:
      discard
    else:
      flat.add($rune)
  flat.strip().truncateRunes(limit)

proc sanitizeSay*(text: string): string =
  ## The network radio call as it reaches the replay and the match feed.
  sanitizeLine(text, MaxSayRunes)

proc sanitizeNote*(text: string): string =
  sanitizeLine(text, MaxNoteRunes)

# ---------------------------------------------------------------------------
#  splitmix64 — the one hash the sim uses, for the reset draw and for the
#  malfunction table. Integer only; identical native and in wasm32.
# ---------------------------------------------------------------------------

proc splitmix64*(state: var uint64): uint64 =
  state = state + 0x9E3779B97F4A7C15'u64
  var z = state
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc mix64*(seed: uint64, a, b: int): uint64 =
  ## The pure `(seed, trainId, tick)` malfunction hash. NOT a consumed stream:
  ## every `(train, tick)` pair is evaluated independently, so no ordering of
  ## decisions by any seat can shift another train's draws (design note
  ## §Sim module -> "Two seeded sources").
  var state = seed xor (uint64(a) * 1000003'u64) xor
    (uint64(b) * 6364136223846793005'u64)
  discard splitmix64(state)
  splitmix64(state)

type
  Rng* = object
    ## The reset draw's splitmix64 stream. Consumed in one fixed order.
    state*: uint64

proc initRng*(seed: uint64): Rng =
  Rng(state: seed)

proc nextUint*(rng: var Rng): uint64 =
  splitmix64(rng.state)

proc rand*(rng: var Rng, bound: int): int =
  ## Uniform in `0 ..< bound`. Integer only.
  if bound <= 1:
    return 0
  int(rng.nextUint() mod uint64(bound))

proc shuffle*[T](rng: var Rng, items: var seq[T]) =
  ## Fisher-Yates, descending, so the consumption order is fixed.
  var i = items.len - 1
  while i > 0:
    let j = rng.rand(i + 1)
    swap(items[i], items[j])
    dec i
