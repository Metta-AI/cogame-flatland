#!/usr/bin/env bash
# GameVersion discipline, inherited from coworld-ctf.
#
# `src/flatland/sim_types.nim` carries a PREPEND-ONLY changelog comment above
# `GameVersion`. A change to the sim, the replay codec, the wire types or a
# committed `.rail` map must bump the version and PREPEND a line; an edited
# historical line is a rewrite of the record and fails here.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
types="${repo_dir}/src/flatland/sim_types.nim"

version="$(grep -oP 'GameVersion\* = "\K[^"]+' "${types}")"
test -n "${version}" || { echo "::error::GameVersion is missing"; exit 1; }

if ! grep -q "^  ##   ${version}  " "${types}"; then
  echo "::error::GameVersion ${version} has no changelog line in ${types}."
  echo "::error::PREPEND one; never edit an older line."
  exit 1
fi

echo "GameVersion ${version} is documented"
