## The rail network: the `.rail` file parser, the tile alphabet, the one
## transition rule, the `uint16` transition masks, the node/edge
## decomposition, the id tables, the load-time validator and the
## `(cell, heading)` breadth-first search.
##
## Pure integer arithmetic. No pixie, no pixel queries, no floating point —
## `tests/test_flatland_sim.nim` greps this file for float syntax, because the
## native <-> wasm hash chain is exact only if every number here is an int.
##
## The six committed networks are compiled into the binary AND into the wasm
## module (`RailFiles` below), so the viewer reconstructs the exact network
## from the map NAME the replay carries, with no fetch.

import std/[algorithm, deques, strutils, tables]

import sim_types

const
  ## The tile alphabet. Every tile is defined by its set of ENDS (which of
  ## N/E/S/W the track leaves through); the single transition rule below
  ## generates straights, curves and switches uniformly from it.
  ##   `.` no rail
  ##   `-` E,W   `|` N,S
  ##   `L` N,E   `J` N,W   `r` S,E   `7` S,W
  ##   `T` E,W,S `Y` E,W,N `>` N,S,E `<` N,S,W
  ##   `X` all four, every turn legal
  ##   `+` all four, FLAT CROSSING: straight only, no turning
  ##   `u` `d` `e` `w` dead-end stub facing N / S / E / W
  TileChars* = ".-|LJr7TY><X+udew"

  RailFiles*: array[6, tuple[name, pool, text: string]] = [
    ("main_a", "mainline", staticRead("../../data/rail/main_a.rail")),
    ("main_b", "mainline", staticRead("../../data/rail/main_b.rail")),
    ("main_c", "mainline", staticRead("../../data/rail/main_c.rail")),
    ("branch_a", "branchline", staticRead("../../data/rail/branch_a.rail")),
    ("branch_b", "branchline", staticRead("../../data/rail/branch_b.rail")),
    ("branch_c", "branchline", staticRead("../../data/rail/branch_c.rail"))
  ]

  StationLetters* = "ABCDEFGH"
  SidingIds*: array[6, string] = ["S1", "S2", "S3", "S4", "S5", "S6"]
  JunctionIds*: array[9, string] =
    ["J1", "J2", "J3", "J4", "J5", "J6", "J7", "J8", "J9"]

type
  RailEdge* = object
    ## A maximal chain of two-end cells joining two nodes. Because a cell
    ## holds one train, no train can pass another inside an edge — every edge
    ## is a one-track section.
    nodeA*, nodeB*: int          ## cell indices of the two end nodes
    cells*: seq[int]             ## interior cells, in order from A to B
    parallel*: bool              ## a second edge joins the same node pair
    siding*: int                 ## index into `sidingIds`, or -1
    oneWayFrom*: int             ## RIGHT-HAND RUNNING (divergence 10): on a
    oneWayTo*: int               ## paired road the router may only traverse
                                 ## from `oneWayFrom` to `oneWayTo`; -1/-1 on
                                 ## every single-track edge.

  RailMap* = ref object
    name*, pool*: string
    width*, height*: int
    tiles*: seq[char]
    ends*: seq[uint8]            ## bit `d` set = the tile has an end facing `d`
    trans*: seq[uint16]          ## bit (3-inDir)*4 + (3-outDir)
    railCells*: seq[int]
    stationOf*: seq[int]         ## -1, or 0 .. 7
    stationCells*: seq[seq[int]] ## 8 entries, three platform cells each
    isNode*: seq[bool]
    nodeLabels*: seq[string]     ## per cell: "" or a station letter / J id
    edgeOf*: seq[int]            ## per interior cell: its edge id, else -1
    edgeFwd*: seq[Dir]           ## per interior cell: the heading that runs A->B
    edges*: seq[RailEdge]
    edgesAtNode*: seq[seq[int]]  ## per cell: edge ids touching it (nodes only)
    sidingEdge*: array[6, int]   ## siding id -> edge id
    junctionCell*: array[9, int] ## junction id -> cell index

proc cellIndex*(map: RailMap, x, y: int): int {.inline.} =
  y * map.width + x

proc cellX*(map: RailMap, index: int): int {.inline.} = index mod map.width
proc cellY*(map: RailMap, index: int): int {.inline.} = index div map.width

proc hasEnd*(map: RailMap, cell: int, d: Dir): bool {.inline.} =
  (map.ends[cell] and (1'u8 shl int(d))) != 0

proc endCount*(map: RailMap, cell: int): int {.inline.} =
  var n = 0
  for d in 0 .. 3:
    if (map.ends[cell] and (1'u8 shl d)) != 0:
      inc n
  n

proc isRail*(map: RailMap, cell: int): bool {.inline.} =
  cell >= 0 and cell < map.tiles.len and map.tiles[cell] != '.'

proc step*(map: RailMap, cell: int, d: Dir): int =
  ## The 4-connected neighbour, or -1 off the grid. The grid does not wrap
  ## (upstream: "the grid does not wrap").
  let
    x = map.cellX(cell)
    y = map.cellY(cell)
  var nx = x
  var ny = y
  case int(d)
  of 0: dec ny
  of 1: inc nx
  of 2: inc ny
  else: dec nx
  if nx < 0 or ny < 0 or nx >= map.width or ny >= map.height:
    -1
  else:
    ny * map.width + nx

proc transitionBit(inDir, outDir: Dir): int {.inline.} =
  (3 - int(inDir)) * 4 + (3 - int(outDir))

proc canExit*(map: RailMap, cell: int, heading, exitDir: Dir): bool {.inline.} =
  ## The runtime form of the one transition rule, read off the `uint16` mask.
  (map.trans[cell] and (1'u16 shl transitionBit(heading, exitDir))) != 0

proc legalExits*(map: RailMap, cell: int, heading: Dir): seq[Dir] =
  ## Every legal exit heading for a train entering `cell` travelling
  ## `heading`, in the fixed end order N, E, S, W. Empty on a dead end, where
  ## the caller reverses.
  for d in 0 .. 3:
    if map.canExit(cell, heading, Dir(d)):
      result.add(Dir(d))

proc isDeadEnd*(map: RailMap, cell: int): bool {.inline.} =
  map.endCount(cell) == 1

proc exitsFrom*(map: RailMap, cell: int, heading: Dir): seq[Dir] =
  ## The exits a train at `cell` facing `heading` may actually take. This is
  ## `legalExits` plus the two documented special cases:
  ##   * a DEAD END has no exits, so the train reverses and leaves through the
  ##     end it came in (upstream's 180-degree rule);
  ##   * a train that has just been PLACED on a platform cell has not entered
  ##     through anything, so its entry end is absent from the tile. It drives
  ##     forward through the end it is facing. `platformOutboundHeading`
  ##     guarantees that end exists, and this branch is unreachable for a
  ##     train that arrived by moving (every link is reciprocal).
  result = map.legalExits(cell, heading)
  if result.len > 0:
    return
  if map.isDeadEnd(cell):
    return @[opposite(heading)]
  if map.hasEnd(cell, heading):
    return @[heading]

# ---------------------------------------------------------------------------
#  Parsing
# ---------------------------------------------------------------------------

proc endsForChar(ch: char): uint8 =
  const N = 1'u8
  const E = 2'u8
  const S = 4'u8
  const W = 8'u8
  case ch
  of '.': 0'u8
  of '-': E or W
  of '|': N or S
  of 'L': N or E
  of 'J': N or W
  of 'r': S or E
  of '7': S or W
  of 'T': E or W or S
  of 'Y': E or W or N
  of '>': N or S or E
  of '<': N or S or W
  of 'X', '+': N or S or E or W
  of 'u': N
  of 'd': S
  of 'e': E
  of 'w': W
  else: raise newException(FlatlandError, "unknown rail tile char '" & ch & "'")

proc stateIndex*(map: RailMap, cell: int, heading: Dir): int {.inline.} =
  cell * 4 + int(heading)

proc buildTransitions(map: RailMap) =
  for cell in 0 ..< map.tiles.len:
    var mask = 0'u16
    if map.tiles[cell] == '.':
      map.trans[cell] = 0
      continue
    let crossing = map.tiles[cell] == '+'
    let count = map.endCount(cell)
    for inDir in 0 .. 3:
      let heading = Dir(inDir)
      if not map.hasEnd(cell, opposite(heading)):
        continue          ## a train cannot have entered through a wall
      if count == 1:
        continue          ## dead end: no exits, the sim reverses the train
      if crossing:
        if map.hasEnd(cell, heading):
          mask = mask or (1'u16 shl transitionBit(heading, heading))
        continue
      for outDir in 0 .. 3:
        if Dir(outDir) == opposite(heading):
          continue        ## never back out the way you came in
        if map.hasEnd(cell, Dir(outDir)):
          mask = mask or (1'u16 shl transitionBit(heading, Dir(outDir)))
    map.trans[cell] = mask

proc decompose(map: RailMap) =
  ## Nodes and edges. A NODE is any rail cell that is not a plain two-end
  ## through cell (three or more ends, or a dead-end stub), any flat crossing,
  ## and any station platform cell. An EDGE is a maximal chain of two-end
  ## cells joining two nodes.
  map.isNode = newSeq[bool](map.tiles.len)
  map.edgeOf = newSeq[int](map.tiles.len)
  map.edgeFwd = newSeq[Dir](map.tiles.len)
  map.edgesAtNode = newSeq[seq[int]](map.tiles.len)
  for cell in map.railCells:
    map.edgeOf[cell] = -1
    # A NODE is any cell that is not a plain two-end through cell, plus every
    # flat crossing. Station platform cells are deliberately NOT nodes: a
    # platform inside a double-track road would split that road into four
    # edges while its partner stayed one, the pair would stop being a pair,
    # and the right-hand running rule below would have nothing to bind to --
    # i.e. no station could ever sit on double track. Nothing needs a platform
    # to be a node: arrival is decided by `stationOf`, route labels by
    # `nodeLabels`, and this game has no station dwell time (out of scope), so
    # a train never stops inside a section at a platform.
    map.isNode[cell] = map.endCount(cell) != 2 or map.tiles[cell] == '+' 

  # Each edge is discovered twice, once from each of its end nodes. The walk
  # records the arrival heading, so the mirror walk's start state
  # `(cur, opposite(heading))` can be struck off in the same pass — which is
  # what keeps two PARALLEL edges between the same node pair as two edges
  # while a single edge stays one.
  var walked = newSeq[bool](map.tiles.len * 4)
  for node in map.railCells:
    if not map.isNode[node]:
      continue
    for d in 0 .. 3:
      if not map.hasEnd(node, Dir(d)):
        continue
      if walked[map.stateIndex(node, Dir(d))]:
        continue
      var
        prev = node
        cur = map.step(node, Dir(d))
        heading = Dir(d)
        interior: seq[int]
        headings: seq[Dir]
      if cur < 0:
        raise newException(FlatlandError, "dangling end at cell " & $node)
      while not map.isNode[cur]:
        interior.add(cur)
        headings.add(heading)
        var nxt = -1
        var nxtDir = heading
        for dd in 0 .. 3:
          if not map.hasEnd(cur, Dir(dd)):
            continue
          let cand = map.step(cur, Dir(dd))
          if cand != prev:
            nxt = cand
            nxtDir = Dir(dd)
        if nxt < 0:
          break
        prev = cur
        cur = nxt
        heading = nxtDir
      walked[map.stateIndex(node, Dir(d))] = true
      walked[map.stateIndex(cur, opposite(heading))] = true
      var edge = RailEdge(nodeA: node, nodeB: cur, cells: interior,
                          parallel: false, siding: -1)
      let id = map.edges.len
      for i, c in interior:
        map.edgeOf[c] = id
        map.edgeFwd[c] = headings[i]
      map.edges.add(edge)
      map.edgesAtNode[node].add(id)
      if cur != node:
        map.edgesAtNode[cur].add(id)

  var counts = initCountTable[string]()
  for edge in map.edges:
    counts.inc($min(edge.nodeA, edge.nodeB) & ":" & $max(edge.nodeA, edge.nodeB))
  for edge in map.edges.mitems:
    let key = $min(edge.nodeA, edge.nodeB) & ":" & $max(edge.nodeA, edge.nodeB)
    edge.parallel = counts[key] >= 2
    edge.oneWayFrom = -1
    edge.oneWayTo = -1

  # RIGHT-HAND RUNNING on every paired road (docs/PORTING-FLATLAND.md,
  # divergence 10). Upstream has no interlocking and therefore no need for a
  # running convention; here a double-track section only carries two
  # directions if the router puts each direction on its own road, and on a
  # shared road two opposing trains close a two-node waits-for cycle the first
  # time they meet. The rule is the real-world one and is derived from the
  # geometry of the PAIR alone, so it is deterministic and identical native
  # and in wasm: of a HORIZONTAL pair the northern road runs westbound and the
  # southern eastbound; of a VERTICAL pair the eastern road runs northbound
  # and the western southbound.
  var groups = initTable[string, seq[int]]()
  for id, edge in map.edges:
    let key = $min(edge.nodeA, edge.nodeB) & ":" & $max(edge.nodeA, edge.nodeB)
    groups.mgetOrPut(key, @[]).add(id)
  for key, ids in groups:
    if ids.len != 2:
      continue
    var centroid: array[2, array[2, int]]
    for slot, id in ids:
      let edge = map.edges[id]
      var cx = 0
      var cy = 0
      if edge.cells.len > 0:
        for cell in edge.cells:
          cx += map.cellX(cell)
          cy += map.cellY(cell)
        cx = (cx * 2) div edge.cells.len
        cy = (cy * 2) div edge.cells.len
      else:
        cx = map.cellX(edge.nodeA) + map.cellX(edge.nodeB)
        cy = map.cellY(edge.nodeA) + map.cellY(edge.nodeB)
      centroid[slot] = [cx, cy]
    let
      first = map.edges[ids[0]]
      ax = map.cellX(first.nodeA)
      ay = map.cellY(first.nodeA)
      bx = map.cellX(first.nodeB)
      by = map.cellY(first.nodeB)
      horizontal = abs(bx - ax) >= abs(by - ay)
    if horizontal and centroid[0][1] == centroid[1][1]:
      continue
    if not horizontal and centroid[0][0] == centroid[1][0]:
      continue
    for slot, id in ids:
      let other = 1 - slot
      var wantForward: bool     ## true = traverse this road from A to B
      if horizontal:
        let northern = centroid[slot][1] < centroid[other][1]
        let westbound = northern
        wantForward = westbound == (map.cellX(map.edges[id].nodeB) <
                                    map.cellX(map.edges[id].nodeA))
      else:
        let eastern = centroid[slot][0] > centroid[other][0]
        let northbound = eastern
        wantForward = northbound == (map.cellY(map.edges[id].nodeB) <
                                     map.cellY(map.edges[id].nodeA))
      if wantForward:
        map.edges[id].oneWayFrom = map.edges[id].nodeA
        map.edges[id].oneWayTo = map.edges[id].nodeB
      else:
        map.edges[id].oneWayFrom = map.edges[id].nodeB
        map.edges[id].oneWayTo = map.edges[id].nodeA

proc parseRailText*(text, pool: string): RailMap =
  ## Parses one `.rail` file. Raises `FlatlandError` on anything malformed —
  ## the server refuses to start on a failure, and
  ## `tests/test_flatland_railmap.nim` runs this over every committed map.
  var lines: seq[string]
  for raw in text.splitLines():
    lines.add(raw)
  while lines.len > 0 and lines[^1].len == 0:
    lines.setLen(lines.len - 1)
  if lines.len < 4 or lines[0] != "# flatland rail map v1":
    raise newException(FlatlandError, "bad rail map header")
  let nameParts = lines[1].splitWhitespace()
  if nameParts.len != 2 or nameParts[0] != "name":
    raise newException(FlatlandError, "bad rail map name line")
  let sizeParts = lines[2].splitWhitespace()
  if sizeParts.len != 3 or sizeParts[0] != "size":
    raise newException(FlatlandError, "bad rail map size line")
  result = RailMap(name: nameParts[1], pool: pool,
                   width: parseInt(sizeParts[1]), height: parseInt(sizeParts[2]))
  if result.width != GridWidth or result.height != GridHeight:
    raise newException(FlatlandError,
      "rail map " & result.name & " is not " & $GridWidth & "x" & $GridHeight)
  if lines[3] != "rail":
    raise newException(FlatlandError, "missing `rail` section")
  let h = result.height
  if lines.len < 5 + 2 * h:
    raise newException(FlatlandError, "rail map is truncated")
  result.tiles = newSeq[char](result.width * h)
  result.ends = newSeq[uint8](result.width * h)
  result.trans = newSeq[uint16](result.width * h)
  result.stationOf = newSeq[int](result.width * h)
  for i in 0 ..< result.stationOf.len:
    result.stationOf[i] = -1
  for y in 0 ..< h:
    let row = lines[4 + y]
    if row.len != result.width:
      raise newException(FlatlandError,
        "rail row " & $y & " is " & $row.len & " chars, expected " & $result.width)
    for x in 0 ..< result.width:
      let cell = y * result.width + x
      result.tiles[cell] = row[x]
      result.ends[cell] = endsForChar(row[x])
      if row[x] != '.':
        result.railCells.add(cell)
  if lines[4 + h] != "stations":
    raise newException(FlatlandError, "missing `stations` section")
  result.stationCells = newSeq[seq[int]](StationLetters.len)
  for y in 0 ..< h:
    let row = lines[5 + h + y]
    if row.len != result.width:
      raise newException(FlatlandError, "station row " & $y & " has the wrong width")
    for x in 0 ..< result.width:
      let ch = row[x]
      if ch == '.':
        continue
      let station = StationLetters.find(ch)
      if station < 0:
        raise newException(FlatlandError, "unknown station letter '" & ch & "'")
      let cell = y * result.width + x
      if result.tiles[cell] == '.':
        raise newException(FlatlandError,
          "station " & $ch & " at " & $x & "," & $y & " is not on rail")
      result.stationOf[cell] = station
      result.stationCells[station].add(cell)
  if lines[5 + 2 * h] != "labels":
    raise newException(FlatlandError, "missing `labels` section")
  for i in 0 ..< result.sidingEdge.len:
    result.sidingEdge[i] = -1
  for i in 0 ..< result.junctionCell.len:
    result.junctionCell[i] = -1
  result.nodeLabels = newSeq[string](result.width * h)
  var sidingCell: array[6, int]
  for i in 0 ..< sidingCell.len:
    sidingCell[i] = -1
  var labelOrder: seq[string]
  for i in (6 + 2 * h) ..< lines.len:
    let parts = lines[i].splitWhitespace()
    if parts.len == 0:
      continue
    if parts.len != 3:
      raise newException(FlatlandError, "bad label line: " & lines[i])
    let
      ident = parts[0]
      x = parseInt(parts[1])
      y = parseInt(parts[2])
      cell = y * result.width + x
    if x < 0 or y < 0 or x >= result.width or y >= result.height or
        result.tiles[cell] == '.':
      raise newException(FlatlandError, "label " & ident & " is not on rail")
    labelOrder.add(ident)
    var placed = false
    for s in 0 ..< SidingIds.len:
      if SidingIds[s] == ident:
        sidingCell[s] = cell
        placed = true
    for j in 0 ..< JunctionIds.len:
      if JunctionIds[j] == ident:
        result.junctionCell[j] = cell
        result.nodeLabels[cell] = ident
        placed = true
    if not placed:
      raise newException(FlatlandError, "unknown label id " & ident)
  var wantLabels: seq[string]
  for id in SidingIds:
    wantLabels.add(id)
  for id in JunctionIds:
    wantLabels.add(id)
  if labelOrder != wantLabels:
    raise newException(FlatlandError,
      "rail map " & result.name & " labels are " & labelOrder.join(",") &
      ", expected " & wantLabels.join(","))

  result.buildTransitions()
  result.decompose()

  # A siding label names one CELL of the siding road; bind it to that cell's
  # edge (or, for a dead-end stub, to the edge that terminates there).
  for s in 0 ..< sidingCell.len:
    let cell = sidingCell[s]
    var edgeId = result.edgeOf[cell]
    if edgeId < 0:
      for id, edge in result.edges:
        if edge.nodeA == cell or edge.nodeB == cell:
          edgeId = id
          break
    if edgeId < 0:
      raise newException(FlatlandError,
        "siding " & SidingIds[s] & " does not lie on an edge")
    result.sidingEdge[s] = edgeId
    result.edges[edgeId].siding = s
  for cell in result.railCells:
    if result.stationOf[cell] >= 0:
      result.nodeLabels[cell] = $StationLetters[result.stationOf[cell]]

# ---------------------------------------------------------------------------
#  Search
# ---------------------------------------------------------------------------


proc routingBlocked*(map: RailMap, fromCell, toCell: int, heading: Dir): bool =
  ## True when the move `fromCell -> toCell` would enter a paired road against
  ## its designated direction. The PHYSICS never consults this — `exitsFrom`
  ## and `resolveExit` stay upstream-exact — it is a ROUTING rule, and the
  ## router is the only producer of routes, so no train ever runs the wrong
  ## way down a double-track road.
  let edge = map.edgeOf[toCell]
  if edge < 0:
    return false
  if map.edges[edge].oneWayFrom < 0:
    return false
  let
    forward = map.edgeFwd[toCell] == heading
    allowForward = map.edges[edge].oneWayFrom == map.edges[edge].nodeA
  forward != allowForward

iterator successors*(map: RailMap, cell: int, heading: Dir):
    tuple[cell: int, heading: Dir] =
  ## Every state reachable in one cell-step, in the fixed end order N, E, S, W.
  ## A dead end reverses (upstream's 180-degree rule).
  for d in map.exitsFrom(cell, heading):
    let nxt = map.step(cell, d)
    if nxt >= 0 and map.isRail(nxt) and not map.routingBlocked(cell, nxt, d):
      yield (nxt, d)

proc bfsRoute*(map: RailMap, startCell: int, startHeading: Dir,
               goals: openArray[int]): seq[int] =
  ## Breadth-first search over states `(cell, heading)`. Returns the cell path
  ## from (exclusive) the start cell to the nearest goal cell, or an empty seq
  ## when no route exists. Successors are expanded in the fixed end order and
  ## ties break by lowest `(cellIndex, heading)`, so the route is unique.
  ## Other trains are NOT obstacles here — they move; the interlock and the
  ## occupancy check are enforced at commit time.
  if goals.len == 0:
    return @[]
  var isGoal = newSeq[bool](map.tiles.len)
  for g in goals:
    if g >= 0 and g < isGoal.len:
      isGoal[g] = true
  if isGoal[startCell]:
    return @[]
  let states = map.tiles.len * 4
  var
    prevState = newSeq[int](states)
    visited = newSeq[bool](states)
    queue = initDeque[int]()
  for i in 0 ..< states:
    prevState[i] = -1
  let start = map.stateIndex(startCell, startHeading)
  visited[start] = true
  queue.addLast(start)
  var found = -1
  while queue.len > 0:
    let cur = queue.popFirst()
    let
      cell = cur div 4
      heading = Dir(cur mod 4)
    if isGoal[cell] and cur != start:
      found = cur
      break
    for nxt in map.successors(cell, heading):
      let idx = map.stateIndex(nxt.cell, nxt.heading)
      if visited[idx]:
        continue
      visited[idx] = true
      prevState[idx] = cur
      queue.addLast(idx)
  if found < 0:
    return @[]
  var path: seq[int]
  var cur = found
  while cur != start:
    path.add(cur div 4)
    cur = prevState[cur]
  reverse(path)
  path

proc routeCells*(map: RailMap, startCell: int, startHeading: Dir,
                 goals: openArray[int]): int =
  ## Distance in cells, or -1 when no route exists.
  let path = map.bfsRoute(startCell, startHeading, goals)
  if path.len == 0:
    (if goals.len > 0 and startCell in goals: 0 else: -1)
  else:
    path.len

proc platformOutboundHeading*(map: RailMap, cell: int): Dir =
  ## The heading a train takes when it enters service on a platform cell: the
  ## lowest-index end the routing rules allow it to leave through, so a train
  ## is never placed facing the wrong way down a one-way road. Deterministic
  ## and map-derived, which is all the reset draw needs.
  for d in 0 .. 3:
    if not map.hasEnd(cell, Dir(d)):
      continue
    let nxt = map.step(cell, Dir(d))
    if nxt >= 0 and map.isRail(nxt) and not map.routingBlocked(cell, nxt, Dir(d)):
      return Dir(d)
  for d in 0 .. 3:
    if map.hasEnd(cell, Dir(d)):
      return Dir(d)
  Dir(0)

proc nodeIdOf*(map: RailMap, cell: int): string =
  ## The public id of a node cell: a station letter, a `J` id, or "".
  if cell < 0 or cell >= map.nodeLabels.len:
    return ""
  map.nodeLabels[cell]

proc sidingIndex*(id: string): int =
  for i, name in SidingIds:
    if name == id:
      return i
  -1

proc junctionIndex*(id: string): int =
  for i, name in JunctionIds:
    if name == id:
      return i
  -1

proc stationIndex*(id: string): int =
  if id.len != 1:
    return -1
  StationLetters.find(id[0])

proc sidingCells*(map: RailMap, sidingId: int): seq[int] =
  ## The cells a `siding at S` order parks on: the siding edge's interior, or
  ## its far node when the edge is a dead-end stub with no interior.
  if sidingId < 0 or sidingId >= map.sidingEdge.len:
    return @[]
  let edgeId = map.sidingEdge[sidingId]
  if edgeId < 0:
    return @[]
  result = map.edges[edgeId].cells
  if result.len == 0:
    result = @[map.edges[edgeId].nodeB]

proc goalCellsFor*(map: RailMap, id: string): seq[int] =
  ## Resolves a `route via V` / `siding at S` argument to its goal cells.
  let station = stationIndex(id)
  if station >= 0:
    return map.stationCells[station]
  let siding = sidingIndex(id)
  if siding >= 0:
    return map.sidingCells(siding)
  let junction = junctionIndex(id)
  if junction >= 0 and map.junctionCell[junction] >= 0:
    return @[map.junctionCell[junction]]
  @[]

proc parallelPairs*(map: RailMap): int =
  ## Unordered node pairs joined by two or more distinct edges: the double
  ## track of a `mainline` map and the passing loops of a `branchline` one.
  var counts = initCountTable[string]()
  for edge in map.edges:
    counts.inc($min(edge.nodeA, edge.nodeB) & ":" & $max(edge.nodeA, edge.nodeB))
  for key, count in counts:
    if count >= 2:
      inc result

proc stationsReachable*(map: RailMap): bool =
  ## Every station reachable from every other in the directed
  ## `(cell, heading)` graph.
  for station in 0 ..< map.stationCells.len:
    for cell in map.stationCells[station]:
      block oneStart:
        let d = int(map.platformOutboundHeading(cell))
        var reached = newSeq[bool](map.stationCells.len)
        var visited = newSeq[bool](map.tiles.len * 4)
        var queue = initDeque[int]()
        let start = map.stateIndex(cell, Dir(d))
        visited[start] = true
        queue.addLast(start)
        while queue.len > 0:
          let cur = queue.popFirst()
          let c = cur div 4
          if map.stationOf[c] >= 0:
            reached[map.stationOf[c]] = true
          for nxt in map.successors(c, Dir(cur mod 4)):
            let idx = map.stateIndex(nxt.cell, nxt.heading)
            if not visited[idx]:
              visited[idx] = true
              queue.addLast(idx)
        for s in 0 ..< reached.len:
          if not reached[s] and s != station:
            return false
  true

proc validate*(map: RailMap) =
  ## The load-time validator (design note §The network -> "Validation at
  ## load"). The server refuses to start on a failure.
  for cell in map.railCells:
    for d in 0 .. 3:
      if not map.hasEnd(cell, Dir(d)):
        continue
      let nxt = map.step(cell, Dir(d))
      if nxt < 0 or not map.isRail(nxt):
        raise newException(FlatlandError,
          map.name & ": end " & dirName(Dir(d)) & " at cell " & $cell &
          " leaves the grid")
      if not map.hasEnd(nxt, opposite(Dir(d))):
        raise newException(FlatlandError,
          map.name & ": non-reciprocal end " & dirName(Dir(d)) & " at cell " & $cell)
  for station in 0 ..< map.stationCells.len:
    if map.stationCells[station].len != 3:
      raise newException(FlatlandError,
        map.name & ": station " & $StationLetters[station] & " has " &
        $map.stationCells[station].len & " platform cells, expected 3")
  for cell in map.railCells:
    if map.isNode[cell]:
      continue
    if map.edgeOf[cell] < 0:
      raise newException(FlatlandError,
        map.name & ": cell " & $cell & " belongs to no edge")
  for j in 0 ..< map.junctionCell.len:
    if map.junctionCell[j] < 0:
      raise newException(FlatlandError, map.name & ": junction " & JunctionIds[j] &
        " is missing")
  for s in 0 ..< map.sidingEdge.len:
    if map.sidingEdge[s] < 0:
      raise newException(FlatlandError, map.name & ": siding " & SidingIds[s] &
        " is missing")
  if not map.stationsReachable():
    raise newException(FlatlandError, map.name & ": stations are not all reachable")
  let pairs = map.parallelPairs()
  if map.pool == "mainline" and pairs < 4:
    raise newException(FlatlandError,
      map.name & ": mainline has " & $pairs & " double-track pairs, need >= 4")
  if map.pool == "branchline" and pairs != 5:
    raise newException(FlatlandError,
      map.name & ": branchline has " & $pairs & " passing loops, need exactly 5")

var mapCache: Table[string, RailMap]

proc loadRailMap*(name: string): RailMap =
  ## Loads one compiled-in network by name, validating it once.
  if mapCache.hasKey(name):
    return mapCache[name]
  for entry in RailFiles:
    if entry.name == name:
      let map = parseRailText(entry.text, entry.pool)
      map.validate()
      mapCache[name] = map
      return map
  raise newException(FlatlandError, "no such rail map: " & name)

proc poolNames*(pool: string): seq[string] =
  for entry in RailFiles:
    if entry.pool == pool:
      result.add(entry.name)

proc networkForSeed*(pool: string, seed: uint64): string =
  ## `pool[seed mod 3]` — the idea's "networks seeded", with no
  ## implementation-defined procedural generator (divergence 2).
  let names = poolNames(pool)
  if names.len == 0:
    raise newException(FlatlandError, "no rail maps in pool " & pool)
  names[int(seed mod uint64(names.len))]
