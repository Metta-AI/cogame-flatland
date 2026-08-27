## The Sprite v1 compositor: the sprite/object pools, the baked rail bed and
## the per-frame train and overlay placements. Forked from `coworld-ctf`'s
## `src/ctf/global.nim`, with the three named edits of the design note:
##
## 1. the board is a GRID, not a pixel arena — placements are cell-space
##    coordinates scaled by `CellPx`, and the fov cache and shadowcasting are
##    deleted (occupancy is public by design);
## 2. new pools `TrainSpriteBase` and `RailTileBase`, sized to `MaxTrains` and
##    `MaxRailCells`, filled in id/index order and emitted incrementally like
##    the starter's other object families;
## 3. the rail bed is BAKED once at install (`rig_art.nim`) and shipped as
##    static bands, so the per-frame cost is trains and overlays only.
##
## The wire format is the starter's unchanged, which is why the inherited
## `client/broadcast_core.js` parses it with no edits: `addLayer` /
## `addViewport` / `addSprite` / `addObject` out of `bitworld/spriteprotocol`,
## with the broadcast chrome smuggled as the LABEL of the reserved 1x1 sprite
## `BroadcastChromeSpriteId`.

import std/[sets, strutils, tables]

import pixie
import bitworld/spriteprotocol

import sim_types, railmap, rig_art

const
  BoardLayer* = 0
  BroadcastChromeSpriteId* = 4090
  StaticBandZ* = -32768
  StaticBandMinId* = 40
  StaticBandMaxId* = 99
  BandHeight* = 40
  BandCount* = (BoardHeight + BandHeight - 1) div BandHeight
  RailTileBase* = StaticBandMinId          ## the baked bed's band pool
  TrainSpriteBase* = 100                   ## 64 locomotive chips
  OverlaySpriteBase* = 200                 ## held / broken / deadlock / late / tint
  TrainObjectBase* = 1000
  OverlayObjectBase* = 2000
  MaxNewSpritesPerPacket* = 4
    ## The bed bands are ~90 KB of RGBA each; trickling them keeps any single
    ## packet well under the hosted replay's 1 MiB websocket frame limit and
    ## fills the board in the first two frames.

type
  GlobalViewerState* = object
    ## One viewer's incremental state: which sprites it has been sent and
    ## where each object was last placed, so a packet only carries changes.
    sentSprites*: HashSet[int]
    placed*: Table[int, array[5, int]]     ## object id -> x, y, z, layer, sprite
    announced*: bool
    replaySeekTick*: int
    replayCommands*: seq[string]

  TrainPlacement* = object
    ## Everything the compositor needs about one train, in cell space.
    active*: bool
    cell*: int
    seat*: int
    speed*: int
    facing*: int
    held*: bool
    broken*: bool
    deadlocked*: bool
    late*: bool

proc initGlobalViewerState*(): GlobalViewerState =
  result.sentSprites = initHashSet[int]()
  result.placed = initTable[int, array[5, int]]()
  result.replaySeekTick = -1

proc applyGlobalViewerMessage*(viewer: var GlobalViewerState, message: string) =
  ## Transport commands arrive on the same socket as everything else, as Sprite
  ## v1 chat packets. `s:<tick>` is a scrubber seek; everything else is a
  ## transport command the caller interprets.
  for parsed in parseSpriteClientMessages(message):
    if parsed.kind != SpriteClientChatMessage:
      continue
    let text = parsed.text
    if text.len > 2 and text[0] == 's' and text[1] == ':':
      try:
        viewer.replaySeekTick = parseInt(text[2 .. ^1])
      except CatchableError:
        discard
    else:
      viewer.replayCommands.add(text)

proc addSpriteOnce(packet: var seq[uint8], viewer: var GlobalViewerState,
                   id: int, image: Image, budget: var int): bool =
  if id in viewer.sentSprites:
    return true
  if budget <= 0:
    return false
  dec budget
  viewer.sentSprites.incl(id)
  packet.addSprite(id, image.width, image.height, image.rgbaBytes())
  true

proc placeObject(packet: var seq[uint8], viewer: var GlobalViewerState,
                 id, x, y, z, layer, sprite: int) =
  let want = [x, y, z, layer, sprite]
  if viewer.placed.getOrDefault(id, [-1, -1, -1, -1, -1]) == want:
    ## The server re-describes the board every frame; broadcast_core only
    ## treats a CHANGE as a change, so re-sending an identical placement is
    ## free. Skipping it here keeps the packet small anyway.
    discard
  viewer.placed[id] = want
  packet.addObject(id, x, y, z, layer, sprite)

proc dropObject(packet: var seq[uint8], viewer: var GlobalViewerState, id: int) =
  if viewer.placed.hasKey(id):
    viewer.placed.del(id)
    packet.addDeleteObject(id)

proc buildViewerPacket*(map: RailMap, trains: openArray[TrainPlacement],
                        viewer: var GlobalViewerState,
                        chromeJson: string): seq[uint8] =
  ## One frame. Layer and viewport first (the client tolerates the restatement
  ## and only reallocates on a real resize), then any sprites this viewer has
  ## not seen, then every object.
  var budget = MaxNewSpritesPerPacket
  if not viewer.announced:
    viewer.announced = true
    result.addLayer(BoardLayer, 0, SpriteLayerZoomableFlag)
    result.addViewport(BoardLayer, BoardWidth, BoardHeight)
  else:
    result.addViewport(BoardLayer, BoardWidth, BoardHeight)

  # --- the baked bed, as static bands ---------------------------------------
  let bed = bakeBed(map)
  for band in 0 ..< BandCount:
    let
      id = RailTileBase + band
      top = band * BandHeight
      height = min(BandHeight, BoardHeight - top)
    if id notin viewer.sentSprites:
      if budget <= 0:
        continue
      dec budget
      viewer.sentSprites.incl(id)
      let slice = newImage(BoardWidth, height)
      slice.draw(bed, translate(vec2(0, float32(-top))))
      result.addSprite(id, BoardWidth, height, slice.rgbaBytes())
    result.placeObject(viewer, id, 0, top, StaticBandZ, BoardLayer, id)

  # --- trains ---------------------------------------------------------------
  let
    chips = bakeChips()
    overlays = bakeOverlays()
  for index, train in trains:
    let
      objectId = TrainObjectBase + index
      overlayId = OverlayObjectBase + index
    if not train.active or train.cell < 0:
      result.dropObject(viewer, objectId)
      result.dropObject(viewer, overlayId)
      continue
    let
      chip = chipIndex(train.seat, train.speed, train.facing)
      spriteId = TrainSpriteBase + chip
      x = map.cellX(train.cell) * CellPx
      y = map.cellY(train.cell) * CellPx
    if not result.addSpriteOnce(viewer, spriteId, chips[chip], budget):
      continue
    result.placeObject(viewer, objectId, x, y, y, BoardLayer, spriteId)
    var overlay = -1
    if train.deadlocked: overlay = 2
    elif train.broken: overlay = 1
    elif train.held: overlay = 0
    elif train.late: overlay = 3
    if overlay < 0:
      result.dropObject(viewer, overlayId)
      continue
    let overlaySprite = OverlaySpriteBase + overlay
    if not result.addSpriteOnce(viewer, overlaySprite, overlays[overlay], budget):
      result.dropObject(viewer, overlayId)
      continue
    result.placeObject(viewer, overlayId, x, y, y + 1, BoardLayer, overlaySprite)

  # --- the broadcast chrome, as the label of the reserved 1x1 sprite --------
  var pixel = newSeq[uint8](4)
  result.addSprite(BroadcastChromeSpriteId, 1, 1, pixel, chromeJson)
