## Shared test scaffolding: a tiny check harness (no unittest — these files
## compile in both debug and release on every CI run and the import cost
## matters) plus the helpers several suites need.

import std/[json, os, strutils]

import flatland/[sim, directives, baselines]

var checks* = 0

template check*(name: string, body: untyped) =
  block:
    inc checks
    body
    echo "  ok  ", name

proc repoRoot*(): string =
  ## Tests run from the repo root locally (`nim c -r tests/tests.nim`) and from
  ## the root in CI; walk up until the manifest is in sight either way.
  var dir = getCurrentDir()
  for _ in 0 .. 4:
    if fileExists(dir / "coworld_manifest_template.json"):
      return dir
    dir = dir.parentDir()
  getCurrentDir()

proc readRepoFile*(path: string): string =
  readFile(repoRoot() / path)

proc testContext*(game: SimServer, seat: int): OrderContext =
  result.map = game.map
  result.cap = game.config.trainsPerSeat
  for i in game.seatTrains(seat):
    result.trainIds.add(trainId(i))
    result.trainIndex.add(i)
    result.arrived.add(game.trains[i].state == tsArrived)
    result.previous.add(game.trains[i].order)

proc testWorld*(game: SimServer): BaselineWorld =
  BaselineWorld(map: game.map, trains: game.trains, occ: game.occ,
                waitsFor: game.waitsFor, tick: game.tick,
                params: DefaultBaselineParams)

proc playScripted*(seed: uint64, kinds: array[4, Baseline], pool = "mainline",
                   trainsPerSeat = 6, maxTicks = 496): SimServer =
  ## One whole episode with the scripted layer only — no server, no sockets, no
  ## network. Every suite that needs a finished episode uses this.
  var config = defaultGameConfig()
  config.seed = seed
  config.networkPool = pool
  config.trainsPerSeat = trainsPerSeat
  config.maxTicks = maxTicks
  config.parOnTime = if pool == "mainline": 15 else: 9
  result = newSimServer(config)
  for slot in 0 ..< result.seatCount():
    result.seats[slot].kind = "scripted"
    result.seats[slot].baseline = $kinds[slot]
    result.seats[slot].policyLabel = $kinds[slot]
  result.startPlaying()
  while result.phase == Playing:
    if result.tick mod config.turnTicks == 0:
      let world = result.testWorld()
      for seat in 0 ..< 4:
        let directive = scriptedDirective(world, kinds[seat], result.testContext(seat))
        for order in directive.orders:
          result.applyOrder(order.train, TrainOrder(verb: order.verb, arg: order.arg))
    result.step()

proc manifest*(): JsonNode =
  parseJson(readRepoFile("coworld_manifest_template.json"))

proc emptyBoard*(pool = "mainline", seed = 1'u64): SimServer =
  ## A world with every train parked off the grid, for hand-built scenarios.
  var config = defaultGameConfig()
  config.seed = seed
  config.networkPool = pool
  result = newSimServer(config)
  result.startPlaying()
  for i in 0 ..< result.trains.len:
    result.trains[i].state = tsArrived
    result.trains[i].cell = -1
  result.arrivedTotal = 0

proc placeTrain*(game: SimServer, index, cell: int, heading: Dir,
                 ticksPerCell = 1) =
  game.trains[index].state = tsRunning
  game.trains[index].cell = cell
  game.trains[index].heading = heading
  game.trains[index].ticksPerCell = ticksPerCell
  game.trains[index].progress = 0
  game.trains[index].stalledTicks = 0
  game.trains[index].blockedTicks = 0
  game.occ.put(cell, index)

proc straightRun*(game: SimServer): tuple[cell: int, heading: Dir] =
  ## A cell on a long straight run, with a heading the routing rules allow, so
  ## a test can measure clear-track behaviour without hand-picking coordinates.
  var best = (cell: -1, heading: Dir(0), room: 0)
  for edge in game.map.edges:
    if edge.cells.len < 4:
      continue
    let forward = edge.oneWayFrom < 0 or edge.oneWayFrom == edge.nodeA
    for i in 0 ..< edge.cells.len - 2:
      let cell = edge.cells[i]
      if game.map.tiles[cell] notin {'-', '|'}:
        continue
      if game.map.stationOf[cell] >= 0:
        continue
      var straight = 0
      var j = i
      while j < edge.cells.len and game.map.tiles[edge.cells[j]] in {'-', '|'}:
        inc straight
        inc j
      if straight <= best.room:
        continue
      let heading =
        if forward: game.map.edgeFwd[cell] else: opposite(game.map.edgeFwd[cell])
      best = (cell: cell, heading: heading, room: straight)
  doAssert best.cell >= 0, "the board has no straight run to test on"
  (best.cell, best.heading)

proc countFloatSyntax*(source: string): seq[string] =
  ## An honest float grep over a sim source file: any `float`, `sqrt`, `/`
  ## division or decimal literal outside a comment, an import line or a string
  ## literal. `div` and `mod` are the only division this sim is allowed.
  for rawLine in source.splitLines():
    var line = rawLine
    let hash = line.find("##")
    if hash >= 0:
      line = line[0 ..< hash]
    let comment = line.find("# ")
    if comment >= 0:
      line = line[0 ..< comment]
    if line.strip().len == 0 or line.strip().startsWith("import") or
        line.strip().startsWith("export"):
      continue
    var code = newStringOfCap(line.len)
    var inString = false
    var escaped = false
    for ch in line:
      if inString:
        if escaped: escaped = false
        elif ch == '\\': escaped = true
        elif ch == '"': inString = false
        continue
      if ch == '"':
        inString = true
        continue
      code.add(ch)
    if "float" in code or "sqrt(" in code:
      result.add(rawLine)
      continue
    var i = 0
    while i < code.len:
      if code[i] == '/':
        result.add(rawLine)
        break
      if code[i] in {'0' .. '9'} and i + 1 < code.len and code[i + 1] == '.' and
          i + 2 < code.len and code[i + 2] in {'0' .. '9'}:
        result.add(rawLine)
        break
      inc i
