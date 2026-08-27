#!/usr/bin/env python3
"""Authoring tool for the committed `data/rail/*.rail` network files.

The networks are AUTHORED, not procedurally generated at run time (design note
§Sim module -> divergence 2): this script is the drawing surface, its six
outputs are the artefact, and `tests/test_flatland_railmap.nim` pins each
output's sha256. Re-running it must reproduce the committed bytes byte for
byte; changing a map is a GameVersion bump plus a new pinned sha256.

Everything here mirrors the Nim loader in `src/flatland/railmap.nim`: the same
ends rule, the same tile alphabet, the same node/edge decomposition and the
same validation. Two implementations of the same rules is deliberate — the Nim
one is the runtime and this one is the drawing board, and the test suite is
what keeps them honest.

    python3 tools/author_rail_maps.py [--check]
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
from collections import deque

W, H = 28, 14

N, E, S, Wd = 0, 1, 2, 3
DIRS = {N: (0, -1), E: (1, 0), S: (0, 1), Wd: (-1, 0)}
OPPOSITE = {N: S, E: Wd, S: N, Wd: E}

# ends-set (frozenset of direction ids) -> tile char. `X` and `+` share a set;
# a crossing is opted into explicitly by the author.
ENDS_TO_CHAR = {
    frozenset({N}): "u",
    frozenset({S}): "d",
    frozenset({E}): "e",
    frozenset({Wd}): "w",
    frozenset({E, Wd}): "-",
    frozenset({N, S}): "|",
    frozenset({N, E}): "L",
    frozenset({N, Wd}): "J",
    frozenset({S, E}): "r",
    frozenset({S, Wd}): "7",
    frozenset({E, Wd, S}): "T",
    frozenset({E, Wd, N}): "Y",
    frozenset({N, S, E}): ">",
    frozenset({N, S, Wd}): "<",
    frozenset({N, S, E, Wd}): "X",
}


class Sketch:
    """A grid of cells, each holding the set of ends the author has drawn."""

    def __init__(self, name: str):
        self.name = name
        self.ends: dict[tuple[int, int], set[int]] = {}
        self.crossings: set[tuple[int, int]] = set()
        self.stations: dict[str, list[tuple[int, int]]] = {}
        self.labels: list[tuple[str, int, int]] = []

    def link(self, a: tuple[int, int], b: tuple[int, int]) -> None:
        """Draws one reciprocal rail connection between two adjacent cells."""
        ax, ay = a
        bx, by = b
        dx, dy = bx - ax, by - ay
        for d, (ddx, ddy) in DIRS.items():
            if (ddx, ddy) == (dx, dy):
                direction = d
                break
        else:
            raise ValueError(f"{a} and {b} are not 4-adjacent")
        for cell in (a, b):
            if not (0 <= cell[0] < W and 0 <= cell[1] < H):
                raise ValueError(f"{cell} is off the grid")
        self.ends.setdefault(a, set()).add(direction)
        self.ends.setdefault(b, set()).add(OPPOSITE[direction])

    def path(self, cells: list[tuple[int, int]]) -> None:
        for a, b in zip(cells, cells[1:]):
            self.link(a, b)

    def hline(self, y: int, x0: int, x1: int) -> None:
        self.path([(x, y) for x in range(x0, x1 + 1)])

    def vline(self, x: int, y0: int, y1: int) -> None:
        self.path([(x, y) for y in range(y0, y1 + 1)])

    def stub(self, cell: tuple[int, int], direction: int) -> None:
        """A dead-end stub: one cell whose only end faces `direction`."""
        self.ends.setdefault(cell, set()).add(direction)

    def crossing(self, cell: tuple[int, int]) -> None:
        self.crossings.add(cell)

    def station(self, letter: str, cells: list[tuple[int, int]]) -> None:
        self.stations[letter] = list(cells)

    def label(self, ident: str, cell: tuple[int, int]) -> None:
        self.labels.append((ident, cell[0], cell[1]))

    # -- passing loop helpers ------------------------------------------------

    def loop_h(self, x0: int, x1: int, y: int, dip: int) -> tuple[int, int]:
        """A horizontal passing loop: the main run along `y` from x0 to x1 and
        a parallel run along `y + dip` between the same two junction cells.
        Returns the cell to label as the siding (the middle of the loop road).
        """
        assert x1 - x0 >= 3
        self.hline(y, x0, x1)
        self.link((x0, y), (x0, y + dip))
        self.hline(y + dip, x0, x1)
        self.link((x1, y + dip), (x1, y))
        return ((x0 + x1) // 2, y + dip)

    def loop_v(self, y0: int, y1: int, x: int, dip: int) -> tuple[int, int]:
        """A vertical passing loop, the transpose of `loop_h`."""
        assert y1 - y0 >= 3
        self.vline(x, y0, y1)
        self.link((x, y0), (x + dip, y0))
        self.vline(x + dip, y0, y1)
        self.link((x + dip, y1), (x, y1))
        return (x + dip, (y0 + y1) // 2)


# ---------------------------------------------------------------------------
#  Rendering
# ---------------------------------------------------------------------------


def render(sketch: Sketch) -> str:
    rail_rows = []
    for y in range(H):
        row = []
        for x in range(W):
            ends = sketch.ends.get((x, y))
            if not ends:
                row.append(".")
                continue
            key = frozenset(ends)
            if key not in ENDS_TO_CHAR:
                raise ValueError(f"{sketch.name}: no tile for ends {sorted(ends)} at {(x, y)}")
            char = ENDS_TO_CHAR[key]
            if (x, y) in sketch.crossings:
                if char != "X":
                    raise ValueError(f"{sketch.name}: crossing at {(x, y)} is not four-ended")
                char = "+"
            row.append(char)
        rail_rows.append("".join(row))

    station_rows = [["."] * W for _ in range(H)]
    for letter, cells in sorted(sketch.stations.items()):
        for (x, y) in cells:
            station_rows[y][x] = letter

    out = ["# flatland rail map v1", f"name {sketch.name}", f"size {W} {H}", "rail"]
    out.extend(rail_rows)
    out.append("stations")
    out.extend("".join(row) for row in station_rows)
    out.append("labels")
    for ident, x, y in sketch.labels:
        out.append(f"{ident} {x} {y}")
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------------------
#  Validation (mirrors src/flatland/railmap.nim)
# ---------------------------------------------------------------------------


CHAR_TO_ENDS = {char: set(ends) for ends, char in ENDS_TO_CHAR.items()}
CHAR_TO_ENDS["+"] = {N, S, E, Wd}
CHAR_TO_ENDS["."] = set()


def parse(text: str):
    lines = text.split("\n")
    assert lines[0] == "# flatland rail map v1", "bad magic"
    name = lines[1].split()[1]
    w, h = (int(v) for v in lines[2].split()[1:3])
    assert lines[3] == "rail"
    rail = lines[4 : 4 + h]
    assert lines[4 + h] == "stations"
    stations = lines[5 + h : 5 + 2 * h]
    assert lines[5 + 2 * h] == "labels"
    labels = [ln.split() for ln in lines[6 + 2 * h :] if ln.strip()]
    for row in rail + stations:
        assert len(row) == w, f"{name}: row width {len(row)} != {w}"
    return name, w, h, rail, stations, labels


def ends_of(rail, x, y):
    return CHAR_TO_ENDS[rail[y][x]]


def exits(rail, x, y, heading):
    """Legal exit headings for a train that entered (x, y) travelling `heading`."""
    char = rail[y][x]
    ends = CHAR_TO_ENDS[char]
    if char == "+":
        return {heading} if heading in ends else set()
    entry = OPPOSITE[heading]
    if len(ends) == 1:
        return set()  # dead end: handled as a reversal by the sim
    return {d for d in ends if d != entry}


def validate(text: str, pool: str) -> dict:
    name, w, h, rail, stations, labels = parse(text)
    problems = []
    railcells = [(x, y) for y in range(h) for x in range(w) if rail[y][x] != "."]

    # every end points at an in-grid rail cell whose opposite end is present
    for (x, y) in railcells:
        for d in ends_of(rail, x, y):
            dx, dy = DIRS[d]
            nx, ny = x + dx, y + dy
            if not (0 <= nx < w and 0 <= ny < h) or rail[ny][nx] == ".":
                problems.append(f"{name}: dangling end {d} at {(x, y)} ({rail[y][x]})")
                continue
            if OPPOSITE[d] not in ends_of(rail, nx, ny):
                problems.append(
                    f"{name}: non-reciprocal end {d} at {(x, y)}"
                    f" ({rail[y][x]}) -> {(nx, ny)} ({rail[ny][nx]})"
                )

    # stations
    platforms: dict[str, list[tuple[int, int]]] = {}
    for y in range(h):
        for x in range(w):
            ch = stations[y][x]
            if ch == ".":
                continue
            platforms.setdefault(ch, []).append((x, y))
            if rail[y][x] == ".":
                problems.append(f"{name}: station {ch} at {(x, y)} is not on rail")
    if sorted(platforms) != list("ABCDEFGH"):
        problems.append(f"{name}: stations are {sorted(platforms)}, expected A..H")
    for letter, cells in platforms.items():
        if len(cells) != 3:
            problems.append(f"{name}: station {letter} has {len(cells)} platform cells")

    # labels
    ids = [row[0] for row in labels]
    for ident, sx, sy in ((r[0], int(r[1]), int(r[2])) for r in labels):
        if rail[sy][sx] == ".":
            problems.append(f"{name}: label {ident} at {(sx, sy)} is not on rail")
    want = [f"S{i}" for i in range(1, 7)] + [f"J{i}" for i in range(1, 10)]
    if ids != want:
        problems.append(f"{name}: labels are {ids}, expected {want}")

    # node / edge decomposition
    nodes = {
        (x, y)
        for (x, y) in railcells
        if len(ends_of(rail, x, y)) != 2 or rail[y][x] == "+"
    }
    seen_interior: dict[tuple[int, int], int] = {}
    pairs: dict[tuple[tuple[int, int], tuple[int, int]], int] = {}
    for node in sorted(nodes):
        for d in sorted(ends_of(rail, *node)):
            dx, dy = DIRS[d]
            cur = (node[0] + dx, node[1] + dy)
            prev = node
            interior = []
            guard = 0
            while cur not in nodes:
                guard += 1
                if guard > w * h:
                    problems.append(f"{name}: runaway edge from {node}")
                    break
                interior.append(cur)
                nxt = None
                for dd in ends_of(rail, *cur):
                    ddx, ddy = DIRS[dd]
                    cand = (cur[0] + ddx, cur[1] + ddy)
                    if cand != prev:
                        nxt = cand
                if nxt is None:
                    break  # a dead-end stub
                prev, cur = cur, nxt
            for cell in interior:
                seen_interior[cell] = seen_interior.get(cell, 0) + 1
            if cur in nodes:
                key = (min(node, cur), max(node, cur))
                pairs[key] = pairs.get(key, 0) + 1
    for (x, y) in railcells:
        if (x, y) in nodes:
            continue
        count = seen_interior.get((x, y), 0)
        # each interior cell is walked once from each end of its edge
        if count != 2:
            problems.append(f"{name}: cell {(x, y)} belongs to {count / 2} edges, expected 1")
    parallel = sum(1 for key, count in pairs.items() if count >= 4)  # walked twice per edge

    # Directed reachability and the double-track / passing-loop counts are
    # asserted by the Nim loader (`railmap.validate`) and by
    # `tests/test_flatland_railmap.nim`: both depend on the right-hand running
    # restriction, which is a runtime rule this drawing board does not model.
    return {"name": name, "problems": problems, "parallel": parallel, "nodes": len(nodes)}


# ---------------------------------------------------------------------------
#  The six committed networks
# ---------------------------------------------------------------------------


def ring(s: Sketch, top: int, bottom: int, left: int, right: int) -> None:
    s.hline(top, left, right)
    s.hline(bottom, left, right)
    s.vline(left, top, bottom)
    s.vline(right, top, bottom)


def mainline(name: str, c1: int, c2: int, c3: int, right: int, letters: str,
             siding_pick) -> Sketch:
    """A DOUBLE-TRACK SPINE with single-track branches.

    The ring is a chain of paired roads, and the right-hand running rule in
    `railmap.nim` gives each direction its own road, so clockwise traffic runs
    the inner ring and anticlockwise the outer and the two can never meet nose
    to nose. Six of the eight stations sit on that spine. Three vertical
    chords cross the middle: the outer two are doubled below the waist, the
    MIDDLE one is single track from top to bottom, and a single-track
    horizontal chord runs the width of the waist and crosses the middle chord
    on a FLAT CROSSING. Those single-track sections carry the seventh and
    eighth stations, so a quarter of every fleet's journeys have to cross
    track where two trains still can meet - which is the whole game.
    """
    s = Sketch(name)
    loops = [(3, c1), (c1 + 1, c2), (c2 + 1, c3), (c3 + 1, right)]
    s.hline(2, 3, right)
    s.hline(11, 3, right)
    sid = []
    for x0, x1 in loops:
        sid.append(s.loop_h(x0, x1, 2, -1))
    for x0, x1 in loops:
        sid.append(s.loop_h(x0, x1, 11, 1))
    sid.append(s.loop_v(2, 11, 3, -1))
    sid.append(s.loop_v(2, 11, right, 1))

    for x in (c1, c2, c3):
        s.vline(x, 2, 11)
    s.hline(6, c1, c3)
    s.crossing((c2, 6))
    # the two outer chords are doubled below the waist; the middle one is not
    sid.append(s.loop_v(6, 10, c1, -1))
    sid.append(s.loop_v(6, 10, c3, 1))

    def road(x0, x1, y, offset=1):
        return [(x0 + offset, y), (x0 + offset + 1, y), (x0 + offset + 2, y)]

    blocks = [
        road(loops[0][0], loops[0][1], 2),
        road(loops[1][0], loops[1][1], 1),
        road(loops[2][0], loops[2][1], 2),
        road(loops[0][0], loops[0][1], 12),
        road(loops[2][0], loops[2][1], 11),
        road(loops[1][0], loops[1][1], 12),
        [(c2, 3), (c2, 4), (c2, 5)],            # the single-track middle chord
        [(c1 - 1, 7), (c1 - 1, 8), (c1 - 1, 9)],  # the doubled chord's loop road
    ]
    for letter, cells in zip(letters, blocks):
        s.station(letter, cells)

    for i, pick in enumerate(siding_pick):
        s.label(f"S{i + 1}", sid[pick])
    junctions = [(3, 2), (c1, 2), (c2, 2), (c3, 2), (right, 2),
                 (c1, 6), (c3, 6), (3, 11), (right, 11)]
    for i, cell in enumerate(junctions):
        s.label(f"J{i + 1}", cell)
    return s


def branchline(name: str, shift: int, crossing_x: int, letters: str) -> Sketch:
    """Single track throughout with exactly five passing loops."""
    s = Sketch(name)
    ring(s, 1, 12, 1, 26)
    s.hline(6, 1, 26)
    s.vline(13 + shift, 1, 12)
    s.crossing((crossing_x, 6))

    sid = []
    sid.append(s.loop_h(3, 7, 6, -1))
    sid.append(s.loop_h(20, 24, 6, -1))
    sid.append(s.loop_h(4, 8, 12, -1))
    sid.append(s.loop_h(19, 23, 12, -1))
    sid.append(s.loop_v(2, 5, 1, 1))

    # S6 is a dead-end stub siding: a train can be put away there and must
    # reverse out (upstream's dead-end rule), which is the only place on a
    # branchline map where reversing is possible.
    s.link((10 + shift, 1), (10 + shift, 2))
    s.stub((10 + shift, 2), N)
    sid.append((10 + shift, 2))

    blocks = [
        [(15 + shift, 1), (16 + shift, 1), (17 + shift, 1)],
        [(3, 1), (4, 1), (5, 1)],
        [(10, 12), (11, 12), (12, 12)],
        [(15, 12), (16, 12), (17, 12)],
        [(10, 6), (11, 6), (12, 6)],
        [(16, 6), (17, 6), (18, 6)],
        [(1, 9), (1, 10), (1, 11)],
        [(26, 9), (26, 10), (26, 11)],
    ]
    for letter, cells in zip(letters, blocks):
        s.station(letter, cells)

    for i, cell in enumerate(sid):
        s.label(f"S{i + 1}", cell)
    junctions = [
        (13 + shift, 1), (13 + shift, 6), (13 + shift, 12), (1, 6), (26, 6),
        (3, 6), (24, 6), (4, 12), (23, 12),
    ]
    for i, cell in enumerate(junctions):
        s.label(f"J{i + 1}", cell)
    return s


MAPS = [
    ("mainline", mainline("main_a", 9, 15, 21, 25, "ABCDEFGH", [3, 7, 8, 9, 10, 11])),
    ("mainline", mainline("main_b", 8, 14, 20, 24, "CFAHBGDE", [0, 4, 8, 9, 10, 11])),
    ("mainline", mainline("main_c", 10, 16, 22, 26, "GDHBEACF", [2, 6, 8, 9, 10, 11])),
    ("branchline", branchline("branch_a", 0, 13, "ABCDEFGH")),
    ("branchline", branchline("branch_b", 1, 14, "DGBEHCAF")),
    ("branchline", branchline("branch_c", 2, 15, "FAEGCHBD")),
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true",
                        help="validate the committed files instead of rewriting them")
    args = parser.parse_args()

    out_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                           "data", "rail")
    os.makedirs(out_dir, exist_ok=True)
    failed = False
    for pool, sketch in MAPS:
        text = render(sketch)
        report = validate(text, pool)
        path = os.path.join(out_dir, f"{sketch.name}.rail")
        for problem in report["problems"]:
            print("FAIL", problem, file=sys.stderr)
            failed = True
        digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
        if args.check:
            with open(path, "r", encoding="utf-8") as fh:
                on_disk = fh.read()
            if on_disk != text:
                print(f"FAIL {sketch.name}: committed file differs from the authoring script",
                      file=sys.stderr)
                failed = True
        else:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text)
        print(f"{sketch.name:10s} pool={pool:11s} loops={report['parallel']:2d} "
              f"nodes={report['nodes']:3d} sha256={digest}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
