# Dispatching and the network

## What a seat is

`num_agents` is **4**, always. Each seat is a **dispatcher commanding a fleet of six
trains** (four in `branchline`) — the idea's own second option, "one policy per fleet".
The seat count is set by the wall clock, not by taste: all four seats' LLM calls go out
as ONE parallel batch per turn, and at the turn-spacing floor that is 20 requests a
minute against the sidecar's 30/minute per-episode cap. One seat per train would be 24
seats and 120 req/min.

Four seats is also the number that seats **both LLM champions and both scripted fillers
in a single episode**, which makes cross-play scoring true by construction.

## Two name spaces

In-game the seats are **`Alpha`, `Beta`, `Gamma`, `Delta`**. Those aliases are the only
names that appear in an observation, a prompt, an order, a `say`, a radio line or a
sprite label. The seats' real policy names live only in `results.names`, in the
replay's join records and in the viewer's scorebug. `showPlayerLabels` is **false**, so
no in-board sprite can leak an identity. A seat can never learn who it is dispatching
alongside.

Train ids are `T01`…`T24`, allocated in seat order: seat 0 owns `T01`–`T06`, seat 1
`T07`–`T12`, and so on. A train's id is public; its owner's alias is public; its target
and its orders are not.

## What a dispatcher sees

**Infrastructure and block occupancy are public; intentions are private.** A real signal
box sees where every train is; it does not see another box's timetable. That is what
makes "yielding conventions without a central scheduler" the actual problem.

Visible: the whole network once at registration (the ASCII tile grid, the station
letters and their platform cells, the six siding ids, the nine junction ids and a
junction graph); **full block occupancy every turn** (one line per train on the grid:
id, owner alias, cell, heading, speed class, state, stalled ticks); everything about
the seat's own trains; the network radio (every seat's `say` from the previous turn);
and public network statistics.

Hidden: every other seat's trains' targets, scheduled arrivals, routes, orders and
notes; every other seat's real name, policy name and kind; every train's future
malfunction draws; the network pool entry not selected.

```json
{
  "you": "Gamma",
  "dispatchers": ["Alpha", "Beta", "Gamma", "Delta"],
  "turn": 9, "of": 31, "tick": 128, "turn_ticks": 16, "ticks_left": 368,
  "network": {"name": "main_b", "width": 28, "height": 14,
              "stations": ["A","B","C","D","E","F","G","H"],
              "sidings": ["S1","S2","S3","S4","S5","S6"],
              "junctions": ["J1","J2","J3","J4","J5","J6","J7","J8","J9"]},
  "your_trains": [
    {"id": "T13", "state": "running", "cell": [12, 5], "heading": "E",
     "ticks_per_cell": 2, "target": "F", "scheduled_arrival": 210, "ticks_late": 0,
     "order": "run", "order_age_turns": 3, "last_order_result": "running",
     "route_next": ["J4", "S3", "F"], "next_decision": {"node": "J4", "eta_ticks": 6},
     "blocked_ticks_last_turn": 0, "malfunction_left": 0}
  ],
  "block_occupancy": [
    {"id": "T02", "by": "Alpha", "cell": [13, 5], "heading": "E",
     "ticks_per_cell": 1, "state": "running"}
  ],
  "radio": [{"from": "Alpha", "text": "T02 has the down main to J5, hold westbounds at J4"}],
  "network_status": {"arrived": 7, "on_time": 6, "malfunctions": 11,
                     "jam": ["T09", "T21"], "deadlock": [], "deadlock_cells": []},
  "your_notes": "T13 via S3 so T02 keeps the main; release T15 after T02 clears J2"
}
```

`heading` is `N|E|S|W`. `state` is `waiting|running|held|malfunctioning|arrived`.
`last_order_result` is
`running|arrived|held|parked|no_route|no_siding|unknown_train|deadlocked|malfunction` —
the driver's honest report of why the previous order ended. `your_trains` is always
exactly `trainsPerSeat` entries long, so the array shape never changes.

## The orders

One reply, one JSON object:

```json
{"orders": [{"train": "T13", "verb": "siding", "at": "S3"},
            {"train": "T15", "verb": "hold"}],
 "say": "T13 into S3, main is clear for Alpha's T02",
 "notes": "release T15 next turn"}
```

| Field | Cap / domain |
|---|---|
| `orders` | <= `trainsPerSeat` entries. Absent or empty = "every train keeps its order", and the reply is still **usable** |
| `orders[].train` | one of THIS seat's train ids, not already arrived |
| `orders[].verb` | `run` \| `hold` \| `siding` \| `route`, lower-cased before matching |
| `orders[].at` | required iff `verb == "siding"`: a siding id |
| `orders[].via` | required iff `verb == "route"`: a station letter, siding id or junction id |
| `say` | <= 120 runes — the network radio, heard by every seat next turn |
| `notes` | <= 240 runes — private, echoed to this seat only next turn |
| whole reply | <= 4096 bytes read from the provider before parsing |

| Order | What the driver does | Finishes with |
|---|---|---|
| `run` | head for the target station's platform cells | `arrived`, or `no_route` |
| `route via V` | head for `V`, then re-plan to the target automatically | `arrived`, or `no_route` |
| `siding at S` | pull into that siding and `Stop` there | `parked`, or `no_siding` |
| `hold` | stop where it is; a waiting train does not depart | `held` |

**Repair, don't reject.** A train not named keeps the order it had. An order whose
fields do not validate is repaired to that train's previous order, never dropped into
"no order", and counted in `ordersRejected`. Orders naming a train the seat does not
own, or one that has already arrived, are dropped and counted. A reply with a valid
`say` but no `orders` is usable. Every string that lands in the replay is truncated on
RUNE boundaries.

## How to lose

* **Greed.** The obvious shortest route for each of your six jams the network. That is
  exactly what the `timetable` baseline does, and it is the control the league scores
  you against.
* **Committing late.** A siding order given after a train has entered a section does
  nothing: the section is a chain of one-train cells and the train cannot reverse.
  Side it at least two turns before `next_decision.eta_ticks` reaches zero.
* **Silence.** The radio is the only channel. The other three dispatchers cannot see
  your targets, your routes or your orders — only your words.
* **Fighting a deadlock.** A deadlock is permanent. Once the list names one of your
  trains, that train is gone; spend the rest of the episode getting the other five
  through.

## The scripted baselines

Both ship as fillers, and `yielder` is also the server-side fallback (`decide.nim`
imports that exact proc, never a copy). Neither ever emits `say` or `notes` — they are
the dispatchers who will not talk to you.

**`timetable`** — pure greed, no yielding: release as early as possible, run.

**`yielder`** — first matching rule wins:
1. arrived -> no order;
2. waiting -> release only if the first 2 nodes of its route hold fewer than 2 trains,
   else `hold`;
3. stalled >= 8 ticks and the blocking train has a LOWER global train id -> `siding` at
   the nearest siding within 3 nodes ahead, else `hold` for this turn;
4. the next single-track section on the route already holds an opposing train ->
   `siding` before it, else `hold`;
5. `siding` and the contested section is now clear -> `run`;
6. otherwise `run`.

The lower-id tie-break in rule 3 guarantees exactly one train of any opposing pair
yields, which is what actually clears a queue. The four tunables live in
`tools/ci/baseline_tuning.json` and are asserted by `tests/test_flatland_tuning.nim`.
