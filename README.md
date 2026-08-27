# cogame-flatland

**Hundreds of trains, one rail network, and every agent is its own dispatcher.**

A port of [Flatland](https://github.com/flatland-association/flatland-rl)'s *rules
idiom* (AIcrowd / SBB / Deutsche Bahn, NeurIPS 2020) onto the Coworld stack, forked
from [`Metta-AI/coworld-ctf`](https://github.com/Metta-AI/coworld-ctf).

A 28 x 14 grid of track — straights, curves, three-way switches, one flat crossing,
eight stations, six passing sidings, nine named junctions. **Twenty-four trains** run
on it. Each has a start platform, a heading, a target station, a speed class and an
earliest departure tick, and each can break down at any moment for 8–24 ticks and sit
there blocking the line.

**A cell holds one train, so nothing ever collides.** Every would-be collision is a
block, and a block that goes round in a circle is a **deadlock**, which on rails is
permanent — trains cannot reverse. The only number the league reads is how many of
the twenty-four trains reached their station **ON TIME**, and everybody gets the same
number.

There is no central scheduler. **Four dispatchers each command six trains**, they
cannot see each other's timetables, and the only channel between them is a
120-character radio call.

| | |
|---|---|
| Seats | `num_agents = 4`, always |
| Trains | 24 (`mainline`) / 16 (`branchline`) |
| Clock | 496 ticks, one command turn every 16 ticks -> 31 turns |
| Score | `1000 x fleetOnTime + 10 x arrivedTotal + onTime[seat]` — higher is better |
| Policy | a prompt (`PLAYER_PROMPT`) or a scripted baseline (`PLAYER_SCRIPTED=timetable\|yielder`) |
| Replay | a static wasm bundle, never a pod |

## Docs

* [`docs/RULES.md`](docs/RULES.md) — the rules, the tick order and the scoring.
* [`docs/DISPATCHING.md`](docs/DISPATCHING.md) — the network, the orders, and how to
  write a dispatcher prompt.
* [`docs/PORTING-FLATLAND.md`](docs/PORTING-FLATLAND.md) — what is upstream's and
  what diverges, with a reason for every divergence.
* [`docs/PROTOCOL.md`](docs/PROTOCOL.md) — the Coworld contract, the replay format
  and the results document.
* [`docs/plans/2026-08-27-flatland-design.md`](docs/plans/2026-08-27-flatland-design.md)
  — the accepted design note this repo implements.

## Field your own dispatcher

A policy is just a prompt. Reuse this image:

```bash
coworld upload-policy coworld-flatland --name my-flatland \
  --run /bin/flatland-player \
  --secret-env PLAYER_PROMPT="Run a directional railway: single-track sections are
one-way for my trains, and I side anything slower two turns before the meet."
```

The LLM call is made in the **game** server, not the player container — that is the
only pod the platform injects the `anthropic_api_key` coworld secret into. The player
process connects to its seat, sends one registration message and then only receives.

## Build and test

```bash
nim c -r tests/tests.nim              # the whole suite
nim c -r --path:src tests/shard_1.nim # one shard
python3 tools/author_rail_maps.py --check   # the six committed networks
python3 tools/build_broadcast_page.py --check
docker build -t coworld-flatland:ci .
tools/ci/docker_smoke.sh coworld-flatland:ci
tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
```

CI (`.github/workflows/ci.yml`) is the only harness that matters: it runs every test
in debug and release, builds the image, plays one real four-seat episode in raw
Docker, and then opens the built wasm bundle in headless chromium against the replay
that episode produced.
