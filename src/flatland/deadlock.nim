## Jams and deadlocks: the waits-for graph of tick step 10, the weakly
## connected components that are JAMS, and the directed cycle search that
## finds a DEADLOCK.
##
## On rails a deadlock is permanent — trains cannot reverse except at a dead
## end — so this is the failure mode the whole game is about, and the alarm
## the viewer lights. A queue behind a broken train is a delay, not a
## deadlock, which is why a malfunctioning member disqualifies a cycle.

import std/algorithm

import sim_types, trains

type
  JamReport* = object
    jam*: seq[int]            ## every train in an active jam, ascending
    deadlock*: seq[int]       ## every train in an active deadlock, ascending
    deadlockCells*: seq[int]  ## the cells the deadlocked trains are fighting over

proc componentsOf(waitsFor: openArray[int], alive: openArray[bool]): seq[seq[int]] =
  ## Weakly connected components of the waits-for graph, by union-find over
  ## the edges `A -> B`. Deterministic: parents are compared by index.
  var parent = newSeq[int](waitsFor.len)
  for i in 0 ..< parent.len:
    parent[i] = i

  proc find(parent: var seq[int], x: int): int =
    var root = x
    while parent[root] != root:
      root = parent[root]
    var cur = x
    while parent[cur] != root:
      let nxt = parent[cur]
      parent[cur] = root
      cur = nxt
    root

  for a in 0 ..< waitsFor.len:
    let b = waitsFor[a]
    if b < 0 or not alive[a] or not alive[b]:
      continue
    let
      ra = find(parent, a)
      rb = find(parent, b)
    if ra != rb:
      parent[max(ra, rb)] = min(ra, rb)
  var buckets = newSeq[seq[int]](waitsFor.len)
  for i in 0 ..< waitsFor.len:
    if not alive[i]:
      continue
    if waitsFor[i] < 0:
      var incoming = false
      for j in 0 ..< waitsFor.len:
        if alive[j] and waitsFor[j] == i:
          incoming = true
          break
      if not incoming:
        continue
    buckets[find(parent, i)].add(i)
  for bucket in buckets:
    if bucket.len >= 2:
      result.add(bucket)

proc findCycle(waitsFor: openArray[int], eligible: openArray[bool]): seq[int] =
  ## A directed cycle in the waits-for graph over the eligible trains. Each
  ## node has at most one successor, so the search is a walk: from the lowest
  ## eligible index, follow successors until a repeat. Pinned for determinism
  ## (the design note's "DFS from the lowest-indexed member, visiting
  ## successors in ascending train id, returning the first cycle found" — with
  ## out-degree one that walk IS the DFS).
  for start in 0 ..< waitsFor.len:
    if not eligible[start]:
      continue
    var
      seen = newSeq[int](waitsFor.len)
      order: seq[int]
      cur = start
      step = 0
    for i in 0 ..< seen.len:
      seen[i] = -1
    while cur >= 0 and eligible[cur]:
      if seen[cur] >= 0:
        var cycle = order[seen[cur] .. ^1]
        cycle.sort()
        return cycle
      seen[cur] = step
      order.add(cur)
      inc step
      cur = waitsFor[cur]
  @[]

proc analyse*(all: openArray[Train], waitsFor: openArray[int],
              jamTicks, deadlockTicks: int): JamReport =
  ## Tick step 10. `waitsFor[a] = b` means A is stalled and either the cell A
  ## wanted holds B, or A was refused by the interlock and B is the lowest-id
  ## opposing train on that edge.
  var alive = newSeq[bool](all.len)
  for i in 0 ..< all.len:
    alive[i] = all[i].onGrid()

  var jammed = newSeq[bool](all.len)
  for i in 0 ..< all.len:
    jammed[i] = alive[i] and all[i].stalledTicks >= jamTicks
  var jamGraph = newSeq[int](all.len)
  for i in 0 ..< all.len:
    jamGraph[i] = if jammed[i] and waitsFor[i] >= 0 and jammed[waitsFor[i]]:
      waitsFor[i] else: -1
  for component in componentsOf(jamGraph, jammed):
    for train in component:
      result.jam.add(train)
  result.jam.sort()

  var eligible = newSeq[bool](all.len)
  for i in 0 ..< all.len:
    eligible[i] = alive[i] and all[i].stalledTicks >= deadlockTicks and
      all[i].state != tsMalfunctioning
  var cycleGraph = newSeq[int](all.len)
  for i in 0 ..< all.len:
    cycleGraph[i] = if eligible[i] and waitsFor[i] >= 0 and eligible[waitsFor[i]]:
      waitsFor[i] else: -1
  result.deadlock = findCycle(cycleGraph, eligible)
  for train in result.deadlock:
    if all[train].cell >= 0:
      result.deadlockCells.add(all[train].cell)
