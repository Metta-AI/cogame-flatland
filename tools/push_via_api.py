#!/usr/bin/env python3
"""Push the working tree to GitHub through the Git Data API.

The sandbox's git credential helper does not authenticate `git push` to a
coworld repo (the push arrives anonymous), so the repo's history is written
with `gh api` instead: bootstrap the first object through the Contents API
(the Git Data API cannot create a repo's first object -- the ecos 2026-08-23
scar), then blobs -> tree -> commit -> ref.

    python3 tools/push_via_api.py Metta-AI/cogame-flatland main "<message>"
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys


def gh(args, payload=None):
    proc = subprocess.run(
        ["gh", "api"] + args,
        input=None if payload is None else json.dumps(payload).encode(),
        capture_output=True,
    )
    if proc.returncode != 0:
        raise SystemExit(f"gh api {' '.join(args)} failed:\n{proc.stderr.decode()}")
    out = proc.stdout.decode().strip()
    return json.loads(out) if out else {}


def main(argv):
    repo, branch, message = argv[1], argv[2], argv[3]
    files = subprocess.run(["git", "ls-files", "-s"], capture_output=True,
                           check=True).stdout.decode().splitlines()
    entries = []
    for line in files:
        meta, path = line.split("\t", 1)
        mode = meta.split()[0]
        entries.append((mode, path))
    print(f"{len(entries)} files")

    head = None
    try:
        ref = gh([f"repos/{repo}/git/ref/heads/{branch}"])
        head = ref["object"]["sha"]
        print(f"existing head {head[:8]}")
    except SystemExit:
        print("empty repo: bootstrapping the first object via the Contents API")
        with open("README.md", "rb") as fh:
            content = base64.b64encode(fh.read()).decode()
        gh([f"repos/{repo}/contents/README.md", "-X", "PUT", "--input", "-"],
           {"message": "bootstrap", "content": content, "branch": branch})
        ref = gh([f"repos/{repo}/git/ref/heads/{branch}"])
        head = ref["object"]["sha"]
        print(f"bootstrapped head {head[:8]}")

    tree = []
    for index, (mode, path) in enumerate(entries):
        with open(path, "rb") as fh:
            raw = fh.read()
        blob = gh([f"repos/{repo}/git/blobs", "--input", "-"],
                  {"content": base64.b64encode(raw).decode(), "encoding": "base64"})
        tree.append({"path": path, "mode": mode, "type": "blob", "sha": blob["sha"]})
        if (index + 1) % 20 == 0:
            print(f"  {index + 1}/{len(entries)} blobs")
    print(f"  {len(entries)}/{len(entries)} blobs")

    created = gh([f"repos/{repo}/git/trees", "--input", "-"], {"tree": tree})
    commit = gh([f"repos/{repo}/git/commits", "--input", "-"],
                {"message": message, "tree": created["sha"], "parents": [head]})
    gh([f"repos/{repo}/git/refs/heads/{branch}", "-X", "PATCH", "--input", "-"],
       {"sha": commit["sha"], "force": True})
    print(f"pushed {commit['sha']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
