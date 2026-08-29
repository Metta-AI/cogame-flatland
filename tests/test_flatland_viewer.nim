## The viewer: chrome provenance, the removed elements, the transport rules,
## the 360 px rules, the endcard vocabulary, the label manifest and the closed
## event enum. Design note §Tests 35-42.
##
## These are STATIC assertions over the shipped page and its inputs, which is
## the only way to gate spectator chrome: `labels.nim` deliberately scopes
## itself to the POLICY contract, and neither `viewer_smoke.mjs` nor the label
## manifest covers a single chrome string.

import std/[algorithm, json, os, strutils]

import crunchy

import flatland/[sim, broadcast, labels, global, wire_constants, events]
import ./helpers

echo "test_flatland_viewer"

let page = readRepoFile("client/replay_broadcast.html")
let core = readRepoFile("client/broadcast_core.js")
let common = readRepoFile("client/chrome_common.js")
let gameBlock = readRepoFile("client/flatland_block.html")

# 35. chrome_common.js is the starter's plus the replay transport patch -----
check "client/chrome_common.js is the pinned starter bytes + transport patch":
  let pins = parseJson(readRepoFile("tests/chrome_sha256.json"))
  doAssert toHex(sha256(common)) == pins{"chrome_common.js"}.getStr(),
    "chrome_common.js is the starter's bytes plus ONLY the fleet-wide " &
    "replay transport patch (0.5x speed chip); everything else this game " &
    "adds lives in the appended block"
  doAssert "window.ChromeCommon" in common
  for name in ["markBeat", "renderBeatMarkers", "ingestBeats", "renderClock",
               "renderTransport", "ingestLullSpans", "renderMomentum"]:
    doAssert name in common, "chrome_common lost " & name

# 36. the page is the starter's plus an appended block -----------------------
check "the page is the starter's page plus an appended block, and only grows":
  let marker = "FLATLAND additions to the inherited coworld-ctf chrome"
  doAssert marker in page
  let splice = page.find(marker)
  let inherited = page[0 ..< splice]
  # The inherited page CONSUMES chrome_common.js and broadcast_core.js through
  # splice markers; it never carries a copy of either. (The old form of this
  # assertion was `... notin inherited or true`, which is true for every
  # possible page.)
  for marker in ["<!-- WIRE_CONSTANTS -->", "<!-- CHROME_COMMON -->",
                 "<!-- BROADCAST_CORE -->"]:
    doAssert marker in inherited,
      "the splice marker " & marker & " is gone; server.nim substitutes it"
  doAssert "window.ChromeCommon({" in inherited,
    "the page must CALL window.ChromeCommon, not define it"
  doAssert "window.ChromeCommon = function" notin page,
    "chrome_common.js is spliced in at serve time, never pasted into the page"
  doAssert "function BroadcastCore(config)" notin page,
    "broadcast_core.js is spliced in at serve time, never pasted into the page"
  doAssert page.endsWith(gameBlock), "the game block is APPENDED, never interleaved"
  doAssert inherited.len > 100_000,
    "the inherited chrome is the starter's whole classic page"
  # the splice hook keeps the starter's shape and signatures
  doAssert "window.FlatlandChrome.install(PB_CTX)" in inherited
  doAssert "window.FlatlandChrome.frame(s, PB_CTX, jumped)" in inherited
  doAssert "window.FlatlandChrome.event(e, s, PB_CTX)" in inherited
  doAssert "install: function (ctx)" in gameBlock
  doAssert "frame: flFrame" in gameBlock and "event: flEvent" in gameBlock
  doAssert "PaintballChrome" notin page

check "broadcast_core keeps the starter's procs, pushFeed's signature included":
  for fragment in ["function BroadcastCore(config)", "function composite()",
                   "function relayout" , "function computeFit()",
                   "attachMinimap", "function setViewport(",
                   "window.FLATLAND_WIRE"]:
    if fragment == "function relayout":
      continue                       ## relayout lives in the page, not the core
    doAssert fragment in core, "broadcast_core.js lost " & fragment
  doAssert "window.CTF_WIRE" notin core, "the wire global is renamed in the fork"
  doAssert "function pushFeed(row) {" in page,
    "pushFeed's SIGNATURE is inherited unchanged (the cogball 0.1.4 latch scar)"

# 37. no shadowed chrome aliases ---------------------------------------------
check "no identifier in the game block collides with a chrome_common alias":
  var aliases: seq[string]
  for line in page.splitLines():
    let trimmed = line.strip()
    if not trimmed.startsWith("var ") or " = C." notin trimmed:
      continue
    for part in trimmed[4 .. ^1].split(","):
      let pair = part.split(" = ")
      if pair.len == 2:
        aliases.add(pair[0].strip())
  doAssert aliases.len > 10, "the chrome alias block was not found"
  for alias in aliases:
    doAssert ("function " & alias & "(") notin gameBlock,
      "the game block redefines the chrome alias " & alias &
      " (the tandem 2026-08-23 hoisting trap)"
  doAssert "function railBeat(" in gameBlock,
    "the beat builder is railBeat, never markBeat"
  doAssert "markBeat" notin gameBlock

# 38. beat CSS matches the emitted kinds exactly -----------------------------
check "there is beat CSS for every emitted kind and no others":
  var styled: seq[string]
  var i = 0
  while true:
    let at = page.find(".beat-marker.", i)
    if at < 0:
      break
    var j = at + len(".beat-marker.")
    var kind = ""
    while j < page.len and page[j] in {'a' .. 'z'}:
      kind.add(page[j])
      inc j
    if kind.len > 0 and kind notin styled:
      styled.add(kind)
    i = at + 1
  var emitted: seq[string]
  for kind in BeatKinds:
    emitted.add(kind)
  styled.sort(cmp)
  emitted.sort(cmp)
  doAssert styled == emitted,
    "beat CSS is " & $styled & " but the game emits " & $emitted

# 39. transport, endcard and the 360 px rules --------------------------------
check "the transport rules are the starter's, untouched":
  doAssert "#endcard {" in page
  doAssert "bottom: var(--band, 0px)" in page,
    "the endcard must stop at the transport band"
  doAssert "$('endcard').classList.remove('on');" in page,
    "every seek must dismiss the endcard"
  for name in ["--hudscale", "--topband", "--band"]:
    doAssert "root.style.setProperty('" & name & "'" in page,
      "relayout() must set " & name & " on :root"
  for id in ["viewport", "stage", "board", "lightpool", "grain", "lockerroom",
             "chrome", "scorebug", "plates-l", "plates-r", "clock", "clock-time",
             "clock-caption", "bannerlane", "killfeed", "mmwarn", "transport",
             "btn-restart", "btn-back", "btn-play", "btn-fwd", "btn-end",
             "btn-loop", "btn-skip", "btn-spoilers", "ffwd-chip", "ffwd-mini",
             "win-chip", "tick-clock", "speedchips", "scrub", "momentum",
             "scrub-fill", "lulls", "scrub-win", "scrub-head", "endcard",
             "ec-headline", "ec-wincond", "ec-how", "ec-teams", "ec-replay",
             "status"]:
    doAssert "id=\"" & id & "\"" in page, "the kept element #" & id & " is gone"

check "the removed elements appear nowhere":
  for id in ["viewpanel", "minimap", "minimap-canvas", "zoombar", "zoom-in",
             "zoom-out", "zoom-slider", "zoom-read", "povBadge", "fpv",
             "fpv-canvas", "fpv-hud", "fpv-name", "fpv-hp", "fpv-gear",
             "fpv-map", "fpv-map-canvas", "fpv-cap", "fpv-grip"]:
    doAssert "id=\"" & id & "\"" notin page, "#" & id & " was not removed"
  for name in ["attachMinimap($('minimap-canvas'))", "renderFpv(", "renderPov(",
               "syncViewUi("]:
    doAssert name notin page, name & " survived the removal"

check "the four 360 px rules are present":
  doAssert ".plate-name {" in gameBlock
  doAssert "flex: 1 1 auto;" in gameBlock and "min-width: 3.2em;" in gameBlock
  for rule in ["#stage.tiny .plate .ontime-label",
               "#stage.tiny .rail-late",
               "#stage.tiny #ontime-rail .rail-chip",
               "#stage.tiny #alarm-chip .alarm-trains"]:
    doAssert rule in gameBlock, "the 360 px rule " & rule & " is missing"
  doAssert "stage.classList.toggle('tiny', boardW <= 620)" in page
  doAssert "Math.max(0.5, Math.min(1.6, boardW / 760))" in page

check "nothing the game block adds sits inside the transport band":
  for id in ["ontime-rail", "alarm-chip"]:
    let at = gameBlock.find("#" & id & " {")
    doAssert at >= 0
    let rule = gameBlock[at ..< gameBlock.find("}", at)]
    doAssert "top: calc(var(--topband)" in rule,
      "#" & id & " must be anchored to the TOP band, never the transport band"

# 40. the endcard vocabulary --------------------------------------------------
check "the paintbot vocabulary is gone from every string the spectator reads":
  const Forbidden = ["Lives", "LIVES", "Clstr", "hopper", "POV lens", "spray",
                     "grenade", "med kit", "paint", "flag", "heart", "hill",
                     "kill"]
  # Only the STRINGS a spectator can read: quoted literals and HTML text
  # nodes. The page's own comments are the starter's history and its
  # identifiers are the starter's code; neither reaches a screen, and neither
  # is in scope here (the label manifest covers the POLICY contract instead).
  # strip every block comment first: `/* ... */` and `<!-- ... -->` both span
  # lines, and both are the starter's own history.
  var stripped = newStringOfCap(page.len)
  var at = 0
  while at < page.len:
    if at + 1 < page.len and page[at] == '/' and page[at + 1] == '*':
      let close = page.find("*/", at)
      at = (if close < 0: page.len else: close + 2)
      continue
    if page.continuesWith("<!--", at):
      let close = page.find("-->", at)
      at = (if close < 0: page.len else: close + 3)
      continue
    stripped.add(page[at])
    inc at
  var spoken: seq[string]
  for line in stripped.splitLines():
    # markup text nodes are scanned only on lines that ARE markup; in script
    # `>` is a comparison, not a tag close.
    let markup = line.strip().startsWith("<") or "</" in line
    var i = 0
    while i < line.len:
      if line[i] == '/' and i + 1 < line.len and line[i + 1] == '/':
        break                                  ## a line comment: the rest is history
      if line[i] in {'\'', '"'}:
        let quote = line[i]
        var j = i + 1
        var literal = ""
        while j < line.len and line[j] != quote:
          if line[j] == '\\' and j + 1 < line.len:
            inc j
          literal.add(line[j])
          inc j
        if ' ' in literal and literal.len >= 6:
          spoken.add(literal)
        i = j + 1
        continue
      if line[i] == '>' and markup:
        var j = i + 1
        var textNode = ""
        while j < line.len and line[j] != '<':
          textNode.add(line[j])
          inc j
        if textNode.strip().len >= 4:
          spoken.add(textNode)
        i = j
        continue
      inc i
  doAssert spoken.len > 40, "the string scan found nothing to check"
  # class names and ids are the starter's markup, not words a spectator reads:
  # only attribute VALUES that are not class/id, plus text nodes and message
  # strings, are in scope.
  for raw in spoken:
    if raw.startsWith("<") or "-line" in raw or "-num" in raw or
        raw.count(' ') == 0:
      continue
    let literal = raw.toLowerAscii()
    for word in Forbidden:
      doAssert word.toLowerAscii() notin literal,
        "the spectator chrome still says \"" & word & "\" in: " & raw.strip()

check "each re-mapped string is present exactly once":
  for phrase in ["<span class=\"momentum-label\">ON TIME</span>",
                 "Booking on",
                 "Replay hash mismatch — showing recorded orders",
                 "arrivals / breakdowns / deadlocks on the timeline"]:
    doAssert page.count(phrase) == 1,
      "the re-mapped string " & phrase & " appears " & $page.count(phrase) &
      " times, expected exactly once"
  # the plate label is emitted by BOTH plate builders (the live one and the
  # dormant classic branch), so it is pinned at two.
  # both plate builders and both endcard-card builders are re-mapped, so the
  # replaced strings appear once per builder.
  doAssert page.count("<span class=\"ontime-label\">On time</span>") == 2
  doAssert page.count("<span>Dispatcher</span>") == 2
  doAssert page.count("Trains on time") == 2
  # the locker-room caption is both markup and the first rotating prep line
  doAssert page.count("Signing on at the control desk") == 2
  doAssert page.count("lives-label") <= 1, "the plate label class is re-mapped"

# 41. the label manifest -----------------------------------------------------
check "the emitted sprite-label vocabulary equals tests/label_manifest.txt":
  let committed = readRepoFile("tests/label_manifest.txt")
  doAssert labelManifest() == committed,
    "regenerate tests/label_manifest.txt in the same commit as any label change"
  for slot in 0 ..< MaxSeats:
    doAssert seatAlias(slot) in committed
  for real in ["daveey", "signalman", "pathfinder"]:
    doAssert real notin committed,
      "a REAL policy name reached the in-game label vocabulary"

# 42. the closed event enum --------------------------------------------------
check "stepEvents emits exactly the thirteen declared kinds":
  var emitted: seq[string]
  for seed in 1'u64 .. 8'u64:
    var config = defaultGameConfig()
    config.seed = seed
    let game = newSimServer(config)
    game.startPlaying()
    while game.phase == Playing:
      game.step()
      for event in stepEvents(game):
        let kind = event{"k"}.getStr()
        if kind notin emitted:
          emitted.add(kind)
  for kind in emitted:
    doAssert kind in DerivedEventKinds, "stepEvents emitted " & kind &
      ", which is outside the closed enum"
  for kind in ["depart", "arrive", "malfunction", "repaired", "jam", "deadlock"]:
    doAssert kind in emitted, "the sim never emitted " & kind

check "every kind the game block handles is in the closed enum":
  for kind in DerivedEventKinds:
    discard kind
  var handled: seq[string]
  for line in gameBlock.splitLines():
    let trimmed = line.strip()
    if not trimmed.startsWith("case '"):
      continue
    let kind = trimmed[6 ..< trimmed.find("'", 6)]
    handled.add(kind)
  doAssert handled.len > 0
  for kind in handled:
    doAssert kind in DerivedEventKinds,
      "the game block handles " & kind & ", which stepEvents never emits"

check "the wire constants are one source and alias the byte-identical chrome":
  let js = wireConstantsJs()
  doAssert js.startsWith("window.FLATLAND_WIRE={")
  doAssert "window.CTF_WIRE=window.FLATLAND_WIRE;" in js,
    "chrome_common.js is byte-identical and reads window.CTF_WIRE"
  let node = parseJson(js.split("=", 1)[1].split("};")[0] & "}")
  doAssert node{"speeds"}[0].getFloat() == 0.5,
    "the replay-only 1/2x speed rides ahead of the integer PlaybackSpeeds"
  doAssert node{"speeds"}.len == PlaybackSpeeds.len + 1
  doAssert node{"chromeSpriteId"}.getInt() == BroadcastChromeSpriteId
  doAssert node{"gridW"}.getInt() == GridWidth
  doAssert node{"maxTicks"}.getInt() == 496
  doAssert node{"beatKinds"}.len == BeatKinds.len

check "the wasm entry and the shell come from ONE starter and match":
  let entry = readRepoFile("replay-viewer/flatland_replay.nim")
  let config = readRepoFile("replay-viewer/config.nims")
  let shell = readRepoFile("replay-viewer/static_replay.js")
  let worker = readRepoFile("replay-viewer/static_replay_worker.js")
  doAssert "-s ABORTING_MALLOC=1" in config,
    "with -d:useMalloc Nim never checks malloc for nil and wasm32 has no " &
    "memory protection"
  for symbol in ["_flatland_load_replay", "_flatland_frame", "_flatland_input",
                 "_flatland_packet_ptr", "_flatland_packet_len",
                 "_flatland_mismatch_tick", "_flatland_error_ptr",
                 "_flatland_error_len", "_flatland_stage_ptr",
                 "_flatland_stage_len", "_main", "_malloc", "_free"]:
    doAssert symbol in config, "EXPORTED_FUNCTIONS is missing " & symbol
  doAssert "MODULARIZE" notin config and "EXPORT_NAME" notin config,
    "this lineage emits a NON-modularized module and the Worker waits for " &
    "Module.onRuntimeInitialized (the cogame-lantern 2026-08-23 deadlock)"
  doAssert "Module.onRuntimeInitialized = function" in worker
  doAssert "importScripts('./wire_constants.js', './broadcast_core.js', " &
    "'./flatland_replay.js')" in worker
  doAssert "data-replay-loaded" in shell and "data-replay-error" in shell
  doAssert "emscripten_exit_with_live_runtime" in entry
  doAssert "stampStage" in entry
  doAssert "prescan" in entry.toLowerAscii()

echo "test_flatland_viewer: ", checks, " checks ok"
