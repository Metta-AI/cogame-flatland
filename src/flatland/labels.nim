## The sprite-label vocabulary contract. Forked from `coworld-ctf`'s
## `src/ctf/labels.nim`, and it keeps that file's scope note: this covers the
## POLICY contract — every string a seat can ever see on the board or in an
## observation — and deliberately NOT the spectator chrome, which
## `tests/test_flatland_endcard_labels.nim` covers instead.
##
## `tests/label_manifest.txt` pins the emitted vocabulary; regenerate it in
## the same commit as any label change.

import std/[algorithm, sets, strutils]

import sim_types, railmap

proc labelVocabulary*(): seq[string] =
  ## Every label this game can put on a board sprite or in an observation
  ## enum. Two name spaces: the four ALIASES are in here, the real policy
  ## names are not, and `showPlayerLabels` is false so no in-board sprite can
  ## leak an identity either way.
  var seen = initHashSet[string]()
  var words: seq[string]
  template take(value: string) =
    let candidate = value
    if candidate.len > 0 and not seen.containsOrIncl(candidate):
      words.add(candidate)
  for slot in 0 ..< MaxSeats:
    take(seatAlias(slot))
  for i in 0 ..< MaxTrains:
    take(trainId(i))
  for ch in StationLetters:
    take($ch)
  for id in SidingIds:
    take(id)
  for id in JunctionIds:
    take(id)
  for name in DirNames:
    take(name)
  for state in TrainState:
    take($state)
  for verb in OrderVerb:
    take($verb)
  for outcome in OrderResult:
    take($outcome)
  words.sort()
  words

proc labelManifest*(): string =
  labelVocabulary().join("\n") & "\n"
