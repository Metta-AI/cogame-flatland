#!/usr/bin/env python3
"""Build `client/replay_broadcast.html` from the coworld-ctf starter page.

The rule (playbooks/make-coworld.md §Phase 0, and the cogame-gridlock scar of
2026-08-23) is that the viewer page is the STARTER'S PAGE PLUS AN APPENDED GAME
BLOCK — never a from-scratch page that reuses the starter's ids. This script is
how that is kept honest and reproducible:

  1. take the starter's classic broadcast page verbatim, up to (not including)
     its own `PAINTBALL additions` splice banner;
  2. delete ONLY the elements the design note §Viewer lists as removed —
     `#viewpanel` (the board is a fixed 28x14 grid that fits the frame at every
     width), `#fpv*` and `#povBadge` (there is no per-train point of view worth
     showing), and the paintbot-only beat-marker CSS kinds;
  3. rename the splice hook `window.PaintballChrome` -> `window.FlatlandChrome`,
     keeping `install(PB_CTX)` / `frame(s, ctx, jumped)` / `event(e, s, ctx)`
     with the same signatures;
  4. append `client/flatland_block.html` under the banner comment.

Run it after editing the appended block, and commit the output:

    python3 tools/build_broadcast_page.py [--check]
"""

from __future__ import annotations

import argparse
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STARTER = os.environ.get("CTF_STARTER", "/workspace/starters/coworld-ctf")


def cut_between(lines, start_pred, end_pred, label, exclusive=False):
    """Deletes [start, end], where end is the first line at or after start
    satisfying end_pred; `exclusive` keeps that end line."""
    out = []
    i = 0
    cut = 0
    while i < len(lines):
        if start_pred(lines[i]):
            j = i
            while j < len(lines) and not end_pred(lines[j], j - i):
                j += 1
            if j >= len(lines):
                raise SystemExit(f"no end found for {label}")
            cut += 1
            i = j if exclusive else j + 1
            continue
        out.append(lines[i])
        i += 1
    if cut == 0:
        raise SystemExit(f"nothing matched for {label}")
    return out


def cut_function(lines, name):
    head = re.compile(r"^  function " + re.escape(name) + r"\s*\(")
    return cut_between(lines, lambda l: head.match(l),
                       lambda l, off: off > 0 and l == "  }", f"function {name}")


def cut_exact(lines, needles):
    wanted = set(needles)
    seen = set()
    out = []
    for line in lines:
        stripped = line.strip()
        if stripped in wanted:
            seen.add(stripped)
            continue
        out.append(line)
    missing = wanted - seen
    if missing:
        raise SystemExit(f"these exact lines were not found: {sorted(missing)}")
    return out


def cut_css_rules(text, selectors):
    """Drops every CSS rule whose selector list mentions one of `selectors`.

    A hand-rolled scanner rather than a regex: the sheet has rules whose
    selector carries pseudo-elements and state classes (`#fpv.dragging`,
    `.beat-marker.steal::after`), and dropping the base `.beat-marker` rule by
    accident would unstyle every marker the game DOES emit.
    """
    style_start = text.index("<style>")
    style_end = text.index("</style>")
    head, sheet, tail = (text[:style_start], text[style_start:style_end],
                         text[style_end:])
    out = []
    i = 0
    hits = {selector: 0 for selector in selectors}
    while i < len(sheet):
        brace = sheet.find("{", i)
        if brace < 0:
            out.append(sheet[i:])
            break
        close = sheet.find("}", brace)
        if close < 0:
            out.append(sheet[i:])
            break
        selector = sheet[i:brace]
        rule = sheet[i:close + 1]
        # keep the newline that follows the rule with the rule itself
        end = close + 1
        if end < len(sheet) and sheet[end] == "\n":
            end += 1
            rule = sheet[i:end]
        matched = None
        for candidate in selectors:
            for token in selector.replace(",", " ").split():
                if token == candidate or token.startswith(candidate + ".") \
                        or token.startswith(candidate + ":") \
                        or token.startswith(candidate + "::"):
                    matched = candidate
                    break
            if matched:
                break
        if matched:
            hits[matched] += 1
        else:
            out.append(rule)
        i = end
    missing = [selector for selector, count in hits.items() if count == 0]
    if missing:
        raise SystemExit(f"no CSS rule matched {missing}")
    return head + "".join(out) + tail


def starter_available() -> bool:
    return os.path.exists(os.path.join(STARTER, "client", "replay_broadcast.html"))


def build() -> str:
    with open(os.path.join(STARTER, "client", "replay_broadcast.html"),
              encoding="utf-8") as fh:
        source = fh.read()

    banner = "<!-- ============================================================\n" \
             "     PAINTBALL additions to the inherited coworld-ctf chrome"
    at = source.index(banner)
    page = source[:at]

    # ---- markup: the three removed element families ------------------------
    lines = page.split("\n")
    lines = cut_between(
        lines,
        lambda l: l.strip().startswith("<!-- View controls: zoom the board"),
        lambda l, off: off > 0 and l == "    </div>",
        "#viewpanel markup")
    lines = cut_between(
        lines,
        lambda l: l.strip().startswith("<!-- First-person picture-in-picture:"),
        lambda l, off: off > 0 and l == "    </div>",
        "#fpv markup")
    lines = cut_exact(lines, [
        '<div id="povBadge">\U0001f441 POV lens — click to clear</div>',
    ])

    # ---- script: the FPV pipeline, the POV badge and the zoom cluster ------
    lines = cut_between(
        lines,
        lambda l: l.strip() == "// ---------- pov + mismatch ----------",
        lambda l, off: off > 0 and l.startswith("  function renderMismatch("),
        "fpv + pov pipeline", exclusive=True)
    lines.insert(
        next(i for i, l in enumerate(lines) if l.startswith("  function renderMismatch(")),
        "  // ---------- mismatch ----------")
    lines = cut_between(
        lines,
        lambda l: l.strip().startswith("// The server ships the static minimap wall silhouette"),
        lambda l, off: off > 0 and l == "  }",
        "ingestFpMap")
    lines = cut_between(
        lines,
        lambda l: l.strip() == "// ---- view controls: zoom cluster + minimap ----------------------------",
        lambda l, off: off > 0 and l.strip().startswith("canvas.addEventListener('dblclick'"),
        "zoom cluster + minimap", exclusive=True)
    lines = cut_exact(lines, [
        "renderPov(s);",
        "ingestFpMap(s);",
        "$('povBadge').addEventListener('click', function () { send('v:-1'); });",
        "else if (k === 'z') core.zoomAt(ZOOM_STEP);",
        "else if (k === 'x') core.zoomAt(1 / ZOOM_STEP);",
    ])
    page = "\n".join(lines)

    # the two callbacks that drove the deleted zoom UI
    page = page.replace(
        "    onFirstFrame: function () { core.setViewportFit(); syncViewUi(); },",
        "    onFirstFrame: function () { core.setViewportFit(); },")
    page = page.replace(
        "    onTransform: function (t) { syncViewUi(t); }",
        "    onTransform: function () { }")
    page = page.replace(
        "    if (!dragging) canvas.style.cursor = 'grab';\n", "")

    # ---- CSS: the removed elements and the never-emitted beat kinds --------
    page = cut_css_rules(page, [
        "#viewpanel", "#minimap", "#zoombar",
        ".zbtn", "#zoom-slider", "#zoom-read",
        "#fpv", "#fpv-canvas", ".fpv-hud", ".fpv-name", ".fpv-hp", ".fpv-gear",
        ".fpv-map", ".fpv-cap", ".fpv-grip",
        "#povBadge",
        ".beat-marker.kill", ".beat-marker.steal", ".beat-marker.return",
        ".beat-marker.capture",
        ".ec-heart",
    ])

    # ---- the design note's chrome re-labelling table -----------------------
    # A forked ctf endcard otherwise silently ships paintbot's vocabulary:
    # nothing in the starter's tests, in viewer_smoke.mjs or in the label
    # manifest covers spectator chrome strings.
    for before, after in [
        ("<span>Player</span><span>K</span><span>D</span>"
         "<span>Clstr</span><span>Cap</span>",
         "<span>Dispatcher</span><span>On time</span><span>Arrived</span>"
         "<span>Late by</span><span>Deadlocks</span>"),
        ('<span class="fl-cap">Lives left</span>',
         '<span class="fl-cap">Trains on time</span>'),
        ('<span class="momentum-label">LIVES LEAD</span>',
         '<span class="momentum-label">ON TIME</span>'),
        ('<span class="lives-label">Lives</span>',
         '<span class="ontime-label">On time</span>'),
        ("Filling hoppers with fresh paint&hellip;",
         "Signing on at the control desk&hellip;"),
        ("In the locker room", "Booking on"),
        ("Replay hash mismatch — showing recorded inputs",
         "Replay hash mismatch — showing recorded orders"),
        ("kills / flag story / winner on the timeline ahead of the playhead (o)",
         "arrivals / breakdowns / deadlocks on the timeline ahead of "
         "the playhead (o)"),
        ("Bot locker room &middot; Loading replay",
         "Control office &middot; Loading replay"),
        # the locker-room prep lines: paintbot's whole idle loop, re-voiced for
        # a signal box.
        ("""      'Filling hoppers with fresh paint\u2026',
      'Pump check: one, two. One, two\u2026',
      'Polishing visors to a mirror shine\u2026',
      'Shaking the paint pods awake\u2026',
      'Squats. Even robots warm up\u2026',
      'Topping off the CO\u2082\u2026',
      'Chalking up the wheels\u2026',
      'Reviewing the game plan\u2026'""",
         """      'Signing on at the control desk\u2026',
      'Chalking tomorrow\u2019s pathing on the board\u2026',
      'Testing the block instruments\u2026',
      'Oiling the point motors\u2026',
      'Checking the section keys back in\u2026',
      'Warming the radio set\u2026',
      'Reading the special traffic notice\u2026',
      'Reviewing the working timetable\u2026'"""),
        # The plate CONTENTS are this game's; the plate, the sides, the strip
        # and the clock column stay the starter's (design note §Viewer).
        ("// PAINTBALL: the plate's CONTENTS change (hill time held, live hill",
         "// FLATLAND: the plate's CONTENTS are the seat's on-time count,"),
        ("""'<div class="hillchip" id="hill-' + team + '" title="Hill coverage">\u2014</div>' +""",
         """'<div class="plate-chip" id="chip-' + team + '" title="Arrived of fleet">\u2014</div>' +"""),
        ("""'<span class="lives-label pb-lbl">Hill</span>' +""",
         """'<span class="ontime-label">On time</span>' +"""),
        ("""'<span class="pb-tags pb-lbl" id="tags-' + team + '"></span>' +""",
         """'<span class="plate-late" id="late-' + team + '"></span>' +"""),
        ("""        // PAINTBALL: the big numeral is HILL TIME HELD (M:SS), the chip is
        // live hill coverage, and the sub-line counts tag-outs. '\u2014' until the
        // frame actually carries this team's entry.
        $('lives-' + team).textContent = tr[team] ? fmt(t.held || 0) : '\u2014';
        var chip = $('hill-' + team);
        if (chip) {
          chip.textContent = tr[team] ? (t.cov || 0) + '%' : '\u2014';
          chip.classList.toggle('own', !!t.own);
          chip.style.color = teamCol(team) || PAPER;
        }
        var tagsEl = $('tags-' + team);
        if (tagsEl) {
          tagsEl.textContent = tr[team]
            ? (t.tags || 0) + ' tags \u00b7 ' + (t.cogs || 0) + ' up' : '';
        }""",
         """        // FLATLAND: the big numeral is this seat's ON-TIME count, the chip is
        // arrived-of-fleet, and the sub-line is the lateness it has run up.
        // '\u2014' until the frame actually carries this team's entry.
        $('lives-' + team).textContent = tr[team] ? (t.onTime || 0) : '\u2014';
        var chip = $('chip-' + team);
        if (chip) {
          chip.textContent = tr[team]
            ? (t.arrived || 0) + '/' + (t.fleet || 0) : '\u2014';
          chip.style.color = teamCol(team) || PAPER;
        }
        var lateEl = $('late-' + team);
        if (lateEl) {
          lateEl.textContent = tr[team]
            ? (t.late || 0) + ' late' + (t.fallbacks ? ' \u21af' : '') : '';
        }"""),
        # The dormant classic-mode strings. FL_MODE latches on the first frame,
        # so none of these branches ever runs here — but the words are still in
        # the shipped page, and `tests/test_flatland_viewer.nim` scans every
        # string literal a spectator could read, not just the live ones.
        ("""'<div class="flagicon" id="flag-' + team + '"></div>' +""",
         """'<div class="plate-chip" id="chip-' + team + '"></div>' +"""),
        ("      buildFlag($('flag-' + team), teamCol(team) || AMBER);",
         "      setName('chip-' + team, '');"),
        ("      updateFlag('flag-' + team, team, tr[team] || {}, s);",
         "      setName('chip-' + team, '');"),
        ("""badge = '<span class="badge tk">team kill</span>';""",
         """badge = '<span class="badge tk">own fleet</span>';"""),
        ("""'<span class="ec-heart ' + heartTeam + '" title="Captured the ' + heartTeam + ' heart"></span>'""",
         """'<span class="ec-mark ' + heartTeam + '" title="Cleared a section for ' + heartTeam + '"></span>'"""),
        ("""'<span class="ec-heart-glyph" title="Captured an enemy heart">\u2665</span>'""",
         """'<span class="ec-mark-glyph" title="Cleared a section">\u25c6</span>'"""),
        ("""var marks = endcardBadge('bs', p.tk, 'Backstab \u2014 killed a teammate');""",
         """var marks = endcardBadge('bs', p.tk, 'Blocked one of its own fleet');"""),
        ("""' \u2014 both squads banked the same hill time, so this half scores 0.500 each.';""",
         """' \u2014 both sides ran the same number in, so this half scores 0.500 each.';"""),
        ("""' the hill counts at that tick.';""",
         """' the arrivals count at that tick.';"""),
        ("""how.textContent = hillLine + ' \u2014 full time on the hill clock.';""",
         """how.textContent = hillLine + ' \u2014 full time on the running clock.';"""),
        ("""how.textContent = 'Time expired \u2014 lives tied; ' + winName + ' won on heart progress.';""",
         """how.textContent = 'Time expired \u2014 tied; ' + winName + ' won on arrivals.';"""),
        ("""how.textContent = winName + ' captured the enemy heart.';""",
         """how.textContent = winName + ' ran the last train in.';"""),
        ("""            (t.held || 0) - bestPbRival >= 5 && s.ph === 'playing'""",
         """            (t.onTime || 0) - bestPbRival >= 1 && s.ph === 'playing'"""),
        ("""          if (o !== team) bestPbRival = Math.max(bestPbRival, (tr[o] && tr[o].held) || 0);""",
         """          if (o !== team) bestPbRival = Math.max(bestPbRival, (tr[o] && tr[o].onTime) || 0);"""),
    ]:
        if before not in page:
            raise SystemExit(f"re-labelling anchor not found: {before[:60]!r}")
        page = page.replace(before, after)

    # ---- the splice hook keeps its shape, under this game's name ----------
    page = page.replace("window.PaintballChrome", "window.FlatlandChrome")
    page = page.replace("PB_MODE", "FL_MODE")
    # The classic page latches its game-block mode on the first frame that
    # carries a squad-only field. This game's frames carry `network` instead.
    page = page.replace("if (!FL_MODE && s.regime !== undefined) FL_MODE = true;",
                        "if (!FL_MODE && s.network !== undefined) FL_MODE = true;")
    page = page.replace("window.CtfStaticReplay", "window.FlatlandStaticReplay")
    page = page.replace("<title>Ctf — Broadcast Replay</title>",
                        "<title>Flatland — Broadcast Replay</title>")

    with open(os.path.join(REPO, "client", "flatland_block.html"),
              encoding="utf-8") as fh:
        block = fh.read()
    return page + block


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if not starter_available():
        # CI has no read-only starter mount. The invariants that matter without
        # it -- the splice banner, the appended block being the file's suffix,
        # the removed ids, the re-mapped vocabulary -- are asserted by
        # tests/test_flatland_viewer.nim against the committed page.
        print(f"starter not present at {STARTER}; skipping the rebuild check")
        return 0
    built = build()
    target = os.path.join(REPO, "client", "replay_broadcast.html")
    if args.check:
        with open(target, encoding="utf-8") as fh:
            if fh.read() != built:
                print("FAIL client/replay_broadcast.html is not the built page",
                      file=sys.stderr)
                return 1
        print("replay_broadcast.html matches the starter page + the appended block")
        return 0
    with open(target, "w", encoding="utf-8") as fh:
        fh.write(built)
    print(f"wrote {target} ({len(built)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
