# Porting Flatland

Upstream is [`flatland-association/flatland-rl`](https://github.com/flatland-association/flatland-rl)
(`flatland.envs.rail_env`), the AIcrowd / SBB / Deutsche Bahn environment of the
NeurIPS 2020 Flatland challenge.

**This repo is a rules-idiom reimplementation, not a bit-exact port.** Upstream's
`sparse_rail_generator`, `line_generator`, observation builders and numpy RNG
consumption order are implementation-defined and could not be re-derived inside a wasm
replay; the constants below could, and are.

## What is upstream's

Every one of these is transcribed into `src/flatland/upstream.nim` with its citation
beside it, and `tests/test_flatland_upstream.nim` asserts the shipped constants still
equal them.

| Upstream fact | Value used here | Source |
|---|---|---|
| Action space | `DO_NOTHING 0`, `MOVE_LEFT 1`, `MOVE_FORWARD 2`, `MOVE_RIGHT 3`, `STOP_MOVING 4` | flatland docs, "Observation and Action Spaces" |
| `DO_NOTHING` semantics | a moving train keeps moving, a stopped train stays stopped | same |
| `MOVE_LEFT` / `MOVE_RIGHT` | take the left/right transition if one exists at this cell, else no effect | same |
| Orientation enum | `N 0, E 1, S 2, W 3` | flatland specifications, "Railway Specifications" |
| Neighbourhood | 4-connected, the grid does **not** wrap | same |
| Cell exclusivity | "each cell is exclusive and can only be occupied by one agent at any given time" | same |
| Dead end | moving forward in a dead-end cell turns the train 180 degrees and steps back | `rail_env` module docs |
| Move order | "the actions of the agents are executed in order of their handle" | `rail_env` module docs |
| Malfunctions | a Poisson process (`malfunction_rate`, `min_duration`, `max_duration`); a malfunctioning train cannot act and blocks the paths of others; nothing repairs it early | flatland FAQ; the 2.0 tutorial |
| Speeds | fastest speed is 1, slower speeds lie in (0, 1); no more than 5 profiles | flatland 2.0 tutorial |
| Removal at target | `remove_agents_at_target = True` | `RailEnv` signature |
| Episode length | `max_time_steps = 4 * 2 * (width + height + 20)` -> **496** for 28 x 14 | flatland FAQ |

## What diverges, and why

1. **A rules-idiom reimplementation, not a bit-exact port.** Named above.

2. **The network is authored and seed-selected, not procedurally generated.** Three
   committed `.rail` files per pool with pinned sha256s, chosen by `pool[seed mod 3]`.
   This keeps every episode legible at 360 px, keeps the topology free of the degenerate
   cases a generator produces, and still satisfies "networks seeded".

3. **Speeds are integer `ticksPerCell`, not float fractions.** `1/speed` ticks per cell
   is exactly upstream's fractional-position accumulator for reciprocal speeds, without
   the float — which is what makes the native <-> wasm hash chain exact.

4. **Malfunctions are a pure hash of `(seed, trainId, tick)`, not a consumed Poisson
   stream.** The marginal law per train-tick is the same geometric draw; the difference
   is that the draws are independent of decision order, so nothing a dispatcher does can
   shift another train's draws. That is the strongest form of "malfunctions seeded".

5. **Segment interlock.** Upstream has no interlocking: two trains may enter opposite
   ends of a single-track section and deadlock immediately. With 24 greedy trains that
   ends most episodes in the first thirty ticks and leaves 460 ticks of a static replay.
   The interlock removes only the **single-section head-on**; the deadlocks that matter —
   a train waiting at one section mouth while standing on the junction another train
   needs, closing a cycle across two or more sections — are fully reachable, are what the
   alarm shows, and are the deadlocks yielding conventions actually solve.

6. **Who chooses the action changed, not what the actions are.** Per-tick RL policies are
   replaced by four high-level orders under a deterministic driver. The five-action
   space, the direction enum, the transition rule, the dead-end reversal, the by-handle
   move order, cell exclusivity, malfunction blocking and removal-at-target are
   upstream's.

7. **Scoring is `1000 * fleetOnTime + 10 * arrivedTotal + onTime[s]`** rather than
   upstream's per-agent reward. The league needs a rankable per-seat integer; all the
   underlying quantities are recorded in `results`.

8. **No reversing except at dead ends** (upstream-faithful), which is what makes a
   deadlock terminal — and terminal deadlock is the game.

9. **`maxGames = 1`.** A cooperative game has no side to swap.

10. **Right-hand running on paired roads.** Where two edges join the same pair of nodes
    the section is double track, and the ROUTER may traverse each road in one direction
    only: of a horizontal pair the northern road is westbound and the southern eastbound;
    of a vertical pair the eastern road is northbound and the western southbound. This is
    the real-world convention, it is derived from the map geometry alone (so it is
    deterministic and identical native and in wasm), and it is what lets a double-track
    section actually carry two directions. The PHYSICS is untouched — `exitsFrom` and the
    action repair stay upstream-exact; this is a routing rule, and the router is the only
    producer of routes. Without it two opposing trains close a two-node waits-for cycle
    the first time they meet on any shared road, and the mainline board gridlocks by tick
    forty regardless of how well anyone dispatches.

11. **Station platform cells are not graph nodes.** Upstream has no node/edge
    decomposition at all; this fork needs one for the interlock and for the running
    convention. A platform inside a double-track road would split that road into four
    edges while its partner stayed one, the pair would stop being a pair, and no station
    could ever sit on double track. Nothing needs a platform to be a node: arrival is
    decided by station membership, route labels by the label table, and this game has no
    station dwell time.

## What is deliberately not here

Upstream's observation builders and RL interface (`TreeObsForRailEnv`,
`GlobalObsForRailEnv`, `LocalObsForRailEnv`, predictors, `msg_bits`), a procedural rail
generator, reversing, scored lateness, infrastructure malfunctions, variable speed during
an episode, station dwell times, multi-cell train length and passenger connections. None
of them are in the upstream rules this port reproduces, and none are invented here.
