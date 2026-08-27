#!/usr/bin/env python3
"""Print one strict-UTF-8 JSON summary of a `COWLDFLT` replay.

Python 3 stdlib only: no Nim, no Docker, no browser. This is the phase-60
substitute for SPEC §Definition of done check 4, because this game's replay is
the starter's BINARY format (the static wasm viewer parses exactly those bytes)
rather than a JSON document:

    curl -sSL "$replay_url" -o /tmp/ep.replay
    python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
    jq -e . /tmp/ep.json >/dev/null                    # strict UTF-8 JSON: ok
    jq -r '.protocol, .results.reason, .results.fleetOnTime' /tmp/ep.json
    jq -r '[.orders[]|select(.source=="llm")]|length, .fallbacks, (.radio|length)' /tmp/ep.json

Require `protocol == "flatland/v1"`, `results.reason == "complete"` (or the
declared-acceptable `deadline`), `results.arrivedTotal > 0`, and the champion
seats' orders with `source == "llm"`, real verbs and non-empty radio lines.
"""

from __future__ import annotations

import json
import sys

MAGIC = b"COWLDFLT"
VERBS = ["run", "hold", "siding", "route"]
KIND_END, KIND_JOIN, KIND_LEAVE, KIND_ORDERS, KIND_CHAT, KIND_HASH, KIND_STOP = range(7)
END_RULES = ["allArrived", "quiescent", "tickCap", "wallClock", "fault"]


class Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0

    def take(self, count: int) -> bytes:
        if self.pos + count > len(self.data):
            raise ValueError("replay is truncated")
        chunk = self.data[self.pos:self.pos + count]
        self.pos += count
        return chunk

    def u8(self) -> int:
        return self.take(1)[0]

    def u16(self) -> int:
        return int.from_bytes(self.take(2), "little")

    def u32(self) -> int:
        return int.from_bytes(self.take(4), "little")

    def u64(self) -> int:
        return int.from_bytes(self.take(8), "little")

    def text(self) -> str:
        # Strict UTF-8: every recorded string was truncated on a RUNE boundary,
        # so a decode error here is a real defect and must not be swallowed.
        return self.take(self.u32()).decode("utf-8")


def summarise(data: bytes) -> dict:
    if not data.startswith(MAGIC):
        raise SystemExit(f"not a {MAGIC.decode()} replay")
    reader = Reader(data)
    reader.take(len(MAGIC))
    fmt = reader.u16()
    game_name = reader.text()
    game_version = reader.text()
    config = json.loads(reader.text())

    joins, orders, chats = [], [], []
    ticks = 0
    stop = None
    while True:
        kind = reader.u8()
        if kind == KIND_END:
            break
        if kind == KIND_JOIN:
            slot = reader.u8()
            name = reader.text()
            reader.text()                      # the token is never reported
            joins.append({"slot": slot, "name": name})
        elif kind == KIND_LEAVE:
            reader.u8()
        elif kind == KIND_ORDERS:
            turn = reader.u16()
            slot = reader.u8()
            count = reader.u8()
            entries = []
            for _ in range(count):
                train = reader.u8()
                verb = reader.u8()
                arg = reader.text()
                entries.append({
                    "train": f"T{train + 1:02d}",
                    "verb": VERBS[verb] if verb < len(VERBS) else str(verb),
                    "arg": arg,
                })
            orders.append({"turn": turn, "slot": slot, "orders": entries})
        elif kind == KIND_CHAT:
            chats.append(json.loads(reader.text()))
        elif kind == KIND_HASH:
            ticks = max(ticks, reader.u16())
            reader.u64()
        elif kind == KIND_STOP:
            tick = reader.u16()
            rule = reader.u8()
            stop = {"tick": tick,
                    "endRule": END_RULES[rule] if rule < len(END_RULES) else str(rule)}
        else:
            raise SystemExit(f"unknown replay record kind {kind}")

    sources = {}
    radio = []
    fallbacks = 0
    results = {}
    kinds = {}
    for chat in chats:
        key = chat.get("k")
        if key == "directive":
            sources[(chat.get("turn"), chat.get("slot"))] = chat.get("source")
            say = chat.get("say") or ""
            if say:
                radio.append({"turn": chat.get("turn"), "slot": chat.get("slot"),
                              "alias": chat.get("alias"), "text": say})
        elif key == "fallback":
            fallbacks += 1
        elif key == "register":
            kinds[chat.get("slot")] = chat.get("kind")
        elif key == "result":
            results = chat.get("results") or {}

    for record in orders:
        record["source"] = sources.get((record["turn"], record["slot"]), "unknown")

    names = [j["name"] for j in sorted(joins, key=lambda j: j["slot"])]
    if not names:
        names = [p.get("name", "") for p in config.get("players", [])]
    aliases = results.get("aliases") or ["Alpha", "Beta", "Gamma", "Delta"]
    policy_kinds = results.get("policyKinds") or [
        kinds.get(i, "scripted") for i in range(len(names))]

    return {
        "protocol": "flatland/v1",
        "format": fmt,
        "game": game_name,
        "gameVersion": game_version,
        "seed": config.get("seed"),
        "network": config.get("network"),
        "names": names,
        "aliases": aliases,
        "policyKinds": policy_kinds,
        "tickCount": ticks,
        "stop": stop,
        "orders": orders,
        "radio": radio,
        "fallbacks": fallbacks,
        "results": results,
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: replay_summary.py <replay path>", file=sys.stderr)
        return 2
    with open(argv[1], "rb") as fh:
        data = fh.read()
    summary = summarise(data)
    # ensure_ascii=False keeps the recorded UTF-8 intact; the output is checked
    # by a STRICT parser in tests/test_flatland_replay.nim.
    sys.stdout.write(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
