# Flatland training

The exporter plays ten complete native rail episodes per certified variant.
It records the hosted system prompt, static network briefing, each acting
seat's observation, and a timetable or yielder reply accepted by the
production directive parser. Four dispatchers choose against one turn
state before the native simulator advances. Train and validation sets
split whole episodes by seed.

```sh
nim c -d:release --path:src -o:/tmp/flatland-posttrain tools/export_posttrain.nim
/tmp/flatland-posttrain /tmp/flatland-data 10 mainline
```

The other certified variant is `branchline`. The output contains
`train.jsonl`, `validation.jsonl`, and a manifest with source revision,
seeds, turns played, final scores, and row counts. Ten matches yielded
980/248 mainline and 992/248 branchline train/validation decisions.

From a Metta checkout with the post-training package installed:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/flatland-data --output /tmp/flatland-adapter \
  --model Qwen/Qwen3-0.6B --max-steps 100 --max-length 4096
```

## Numeric reinforcement learning

`tools/train_bridge.nim` exposes the same hosted prompts and 194 numeric
values from the public network state and acting seat's trains. Six map
identities, tick progress, arrival and malfunction counts, public train
occupancy, and own train state, position, target, and current orders are
encoded. It excludes other dispatchers' targets, routes, orders, and
notes. Two choices select the published timetable and yielder baselines.
The native cooperative score is converted to
`score / (score + 1000)` for a bounded [0, 1] utility. Post-training above
retains arbitrary legal directive JSON and radio messages.

```sh
nim c -d:release --path:src -o:/tmp/flatland-train-bridge tools/train_bridge.nim
python3 tools/test_training.py /tmp/flatland-posttrain /tmp/flatland-train-bridge
```

From a Metta checkout with the Coworld training stack, pass absolute
bridge and manifest paths to `recipes.external.coworld.train` for native
PufferLib, or `recipes.external.coworld_metta_rl.train` for Metta RL.
Set `players=4` and choose `mainline` or `branchline`.
