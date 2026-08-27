# Rules

## The board

One rail network, **28 cells wide and 14 tall**, drawn as track: straights, curves,
three-way switches, one flat crossing, **eight stations** (three platform cells each),
**six passing sidings** and **nine named junctions**. The topology is authored, not
generated: six committed files in `data/rail/`, three per pool, and the episode's
network is `pool[seed mod 3]`.

Cells are `(x, y)`, `x` rightwards from 0, `y` downwards from 0; the cell index is
`y*28 + x`. Every tie-break that says "lowest cell index" means that number.

### Tiles and the one transition rule

Every tile is defined by its set of **ends** (which of N/E/S/W the track leaves
through). A train travelling in direction `d` entered the cell through the
`opposite(d)` end; it may leave through **any other end of the tile**, and its new
heading is that end's direction. That single rule generates straights, curves and
switches uniformly.

| Char | Ends | What it is |
|---|---|---|
| `.` | — | no rail |
| `-` | E, W | straight |
| `\|` | N, S | straight |
| `L` | N, E | curve |
| `J` | N, W | curve |
| `r` | S, E | curve |
| `7` | S, W | curve |
| `T` | E, W, S | three-way switch |
| `Y` | E, W, N | three-way switch |
| `>` | N, S, E | three-way switch |
| `<` | N, S, W | three-way switch |
| `X` | N, S, E, W | four-way junction, every turn legal |
| `+` | N, S, E, W | **flat crossing**: straight only, no turning |
| `u` `d` `e` `w` | N / S / E / W | dead-end stub facing that way |

Two exceptions: the flat crossing `+` allows only `N->N, E->E, S->S, W->W`; and a
**dead end** (one end) has an empty exit set, so the train reverses and leaves through
the end it came in — upstream's 180-degree dead-end rule.

### Nodes, edges and sections

A **node** is any rail cell that is not a plain two-end through cell, plus every flat
crossing. An **edge** is a maximal chain of two-end cells joining two nodes. Because a
cell holds one train, **no train can pass another inside an edge** — every edge is a
one-track section. Where two edges join the same pair of nodes the section is **double
track**, and the router runs it right-hand: of a horizontal pair the northern road is
westbound and the southern eastbound; of a vertical pair the eastern road is northbound
and the western southbound.

## The clock

* **Tick** = one Flatland `step`. **`maxTicks = 496`** — upstream's own formula
  `4 * 2 * (width + height + 20)` for a 28 x 14 grid.
* **Command turn** = one order round, every **16 ticks**, beginning with turn 1 at tick
  0 before any stepping. **31 command turns per episode.**
* Between turns the loop runs uncapped, so the 496 ticks cost about a second of CPU;
  the wall clock of an episode is the 31 LLM turns.

## The tick, in order

This is the whole physics of the game and nothing else mutates the world.

1. `tick += 1`; snapshot the occupancy layer.
2. **Malfunction rolls.** For every running train, in ascending id,
   `h = mix64(seed, trainId, tick)`; if `h mod malfunctionRate == 0` it breaks down for
   `8 + ((h >> 32) mod 17)` ticks.
3. **Malfunction countdown.** Every malfunctioning train decrements; at 0 it is
   repaired. A malfunctioning train takes no action and keeps its cell.
4. **Departures.** A waiting train is OFF the board and occupies nothing. It enters at
   or after `earliestDeparture`, only when its platform cell is free, and never while
   its order is `hold`.
5. **One action per running train**, from its order, via the driver. The action is one
   of `DoNothing 0, MoveLeft 1, MoveForward 2, MoveRight 3, Stop 4`.
6. **Progress.** `Stop` accrues none; every other running train increments `progress`,
   capped at its speed class `ticksPerCell`.
7. **Move resolution**, over the trains at `progress == ticksPerCell`, **in ascending
   train id** (upstream: "the actions of the agents are executed in order of their
   handle"):
   * **a.** resolve the exit end; an illegal one is repaired — `MoveForward` if legal,
     else the single legal exit, else the lowest direction index — and counted;
   * **b.** **segment interlock**: entry to an edge already holding an OPPOSING train
     is refused;
   * **c.** if the target cell is on rail and unoccupied, the train moves;
   * **d.** otherwise it does not, and `blockedTicks` increments.
8. **Arrivals.** A train on a platform cell of its target station arrives, is removed
   from the grid, and is **on time** iff `arrivalTick <= scheduledArrival`.
9. **Stall accounting.**
10. **Jam and deadlock detection** over the waits-for graph (below).
11. Mix the tick into `gameHash`.
12. Evaluate the end conditions.

**Collisions cannot occur.** The exclusive-cell rule turns every would-be collision
into a block; `results` carries no `collisions` key and the viewer draws no crash.

## Jams and deadlocks

Build the directed **waits-for** graph over running trains: `A -> B` when A is stalled
and either the cell A wanted holds B, or A was refused by the interlock and B is the
lowest-id opposing train on that edge.

* A **jam** is a weakly connected component with >= 2 members all stalled >= 12 ticks.
* A **deadlock** is a directed **cycle** in which every member is stalled >= 24 ticks
  and **no member is malfunctioning** — a queue behind a broken train is a delay, not a
  deadlock. A deadlock is re-evaluated every tick, not latched: it breaks only if a
  member is re-routed before it commits to the contested edge, which is exactly the
  skill the game rewards. Any deadlock still active at the last tick strands its
  members.

## Scoring

Per train, fixed at reset:

```
routeCells        = BFS distance in cells from (start cell, start heading) to the
                    nearest platform cell of the target, over the directed
                    (cell, heading) graph, ignoring other trains
scheduledArrival  = earliestDeparture + ticksPerCell * routeCells + 24
```

At the end of the episode:

```
arrivedTotal = trains that reached their target station
fleetOnTime  = those whose arrivalTick <= scheduledArrival
scores[s]    = 1000 * fleetOnTime + 10 * arrivedTotal + onTime[s]
```

**Higher is better; no term is ever negative.** Deadlocks, jams, malfunctions, blocked
ticks and lateness subtract nothing — they cost arrivals, which is the only currency.

The first two terms are **identical for all four seats**: pure common interest. The
third is the individual target and is deliberately an epsilon (`onTime[s] <= 6` and
`10 * arrivedTotal <= 240 < 1000`), so the ordering is strictly lexicographic — network
on-time count first, total arrivals second, own on-time trains only as a tie-break — and
a dispatcher who shoves its own six through at the cost of one other seat's on-time
train loses 1000 to gain at most 6.

`results.win[s]` is `fleetOnTime >= parOnTime`, the same boolean for all four seats: a
"did the network run" flag, not a duel. `results.winner` is always `null`.

**Lateness is measured and shown, never scored.**

## End conditions

The episode ends at the first of:

| `endRule` | When | `reason` |
|---|---|---|
| `allArrived` | every train has arrived | `complete` |
| `quiescent` | 120 consecutive ticks with no arrival, no departure, no train entering a new cell and none malfunctioning | `complete` |
| `tickCap` | tick 496 | `complete` |
| `wallClock` | the engine's 660 s stop | `deadline` |
| `fault` | an unexpected exception, caught and settled from the last completed tick | `fault` |

A `deadline` episode is settled with the **real** arrivals so far, never zeroed, so it
is still rankable. A **budget guard** switches the LLM off for every remaining turn the
moment two more full turns would not fit inside the wall-clock stop, so the episode
ends `complete` rather than `deadline`.

A seat that never connects, disconnects mid-episode, or fails every decision **does not
end the episode**: its six trains are dispatched by `yielder` and `deadSeats[s]` is set.
