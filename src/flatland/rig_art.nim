## The sprite compositor's art. Forked from `coworld-ctf`'s `src/ctf/rig_art.nim`
## — the same "bake once at install, blit at run time" shape, retargeted from
## a 128 px articulated soldier rig to rail.
##
## REAL ART, from the starter's shipped assets plus install-time bakes. No
## placeholders, no solid-colour squares, no downloads:
##   * the ballast bed is `data/arena_floor.png`, tiled and darkened 22 %,
##     with the gravel shoulder textured from `client/art/walls/wall_h.jpg`;
##   * the rail tile atlas (two steel rails, sleepers, a check rail on the
##     curves, platform slabs and siding marks) is baked over it from the
##     16-entry palette in `data/pallete.png`;
##   * the train chips are baked by this compositor - four facings x four
##     speed classes x four seat colours = 64 chips - with a lit headlamp, a
##     body length proportional to the speed class and its number set in
##     `data/font.ttf`; the seat colours are read out of
##     `data/soldier_{red,blue,green,yellow}.png`;
##   * station letters, siding ids and junction ids are set in `data/font.ttf`
##     on the baked bed.
## 24 trains a frame is therefore 24 blits.

import std/[algorithm, tables]

import pixie

import sim_types, railmap

const
  CellPx* = 20                    ## board pixels per grid cell
  BoardWidth* = GridWidth * CellPx
  BoardHeight* = GridHeight * CellPx

  FloorPng = staticRead("../../data/arena_floor.png")
  PalettePng = staticRead("../../data/pallete.png")
  ShoulderJpg = staticRead("../../client/art/walls/wall_h.jpg")
  FontTtf = staticRead("../../data/font.ttf")
  SoldierPngs: array[4, string] = [
    staticRead("../../data/soldier_red.png"),
    staticRead("../../data/soldier_blue.png"),
    staticRead("../../data/soldier_green.png"),
    staticRead("../../data/soldier_yellow.png")
  ]

var
  paletteCache: seq[ColorRGBA]
  seatColourCache: seq[ColorRGBA]
  typefaceCache: Typeface
  bedCache: Table[string, Image]
  chipCache: seq[Image]
  overlayCache: seq[Image]

proc palette*(): seq[ColorRGBA] =
  ## The starter's 16-entry retro palette, from `data/pallete.png`.
  if paletteCache.len == 0:
    let image = decodeImage(PalettePng)
    for x in 0 ..< min(16, image.width):
      paletteCache.add(image[x, 0].rgba())
  paletteCache

proc boardTypeface*(): Typeface =
  if typefaceCache.isNil:
    typefaceCache = parseTtf(FontTtf)
  typefaceCache

proc seatColours*(): seq[ColorRGBA] =
  ## One colour per seat, read out of the four shipped soldier sprites: the
  ## most common strongly-saturated opaque pixel in each, which is the team
  ## body colour the starter's art was authored in.
  if seatColourCache.len > 0:
    return seatColourCache
  for png in SoldierPngs:
    let image = decodeImage(png)
    var counts = initCountTable[uint32]()
    for y in 0 ..< image.height:
      for x in 0 ..< image.width:
        let c = image[x, y].rgba()
        if c.a < 250:
          continue
        let
          hi = max(c.r, max(c.g, c.b)).int
          lo = min(c.r, min(c.g, c.b)).int
        if hi - lo < 48 or hi < 80:
          continue
        counts.inc((uint32(c.r) shl 16) or (uint32(c.g) shl 8) or uint32(c.b))
    if counts.len == 0:
      seatColourCache.add(rgba(200, 200, 200, 255))
      continue
    counts.sort()
    var best = 0'u32
    for key, _ in counts:
      best = key
      break
    seatColourCache.add(rgba(uint8((best shr 16) and 0xFF),
                             uint8((best shr 8) and 0xFF),
                             uint8(best and 0xFF), 255))
  seatColourCache

# ---------------------------------------------------------------------------
#  Small deterministic raster helpers. Direct pixel writes, so the bake is
#  byte-identical native and in wasm.
# ---------------------------------------------------------------------------

proc blend(dst: var ColorRGBA, src: ColorRGBA) =
  if src.a == 0:
    return
  if src.a == 255:
    dst = src
    return
  let a = int(src.a)
  dst.r = uint8((int(src.r) * a + int(dst.r) * (255 - a)) div 255)
  dst.g = uint8((int(src.g) * a + int(dst.g) * (255 - a)) div 255)
  dst.b = uint8((int(src.b) * a + int(dst.b) * (255 - a)) div 255)
  dst.a = 255

proc plot(image: Image, x, y: int, colour: ColorRGBA) =
  if x < 0 or y < 0 or x >= image.width or y >= image.height:
    return
  var dst = image[x, y].rgba()
  dst.blend(colour)
  image[x, y] = dst.rgba

proc fillBox(image: Image, x0, y0, w, h: int, colour: ColorRGBA) =
  for y in y0 ..< y0 + h:
    for x in x0 ..< x0 + w:
      image.plot(x, y, colour)

proc darken(colour: ColorRGBA, permille: int): ColorRGBA =
  rgba(uint8(int(colour.r) * permille div 1000),
       uint8(int(colour.g) * permille div 1000),
       uint8(int(colour.b) * permille div 1000), colour.a)

proc drawTextInto(image: Image, text: string, x, y, size: int,
                  colour: ColorRGBA) =
  if text.len == 0:
    return
  var font = newFont(boardTypeface())
  font.size = float32(size)
  font.paint = colour.color
  let box = newImage(max(8, size * text.len), size * 2)
  box.fillText(font, text)
  for by in 0 ..< box.height:
    for bx in 0 ..< box.width:
      let c = box[bx, by].rgba()
      if c.a > 8:
        image.plot(x + bx, y + by, c)

# ---------------------------------------------------------------------------
#  The bed
# ---------------------------------------------------------------------------

proc bakeBed*(map: RailMap): Image =
  ## The whole board, baked ONCE: ballast, shoulder, rails, sleepers,
  ## platforms, siding marks and every label. The per-frame cost is trains and
  ## overlays only.
  if bedCache.hasKey(map.name):
    return bedCache[map.name]
  let
    pal = palette()
    floorTile = decodeImage(FloorPng)
    shoulder = decodeImage(ShoulderJpg)
    steel = rgba(178, 184, 190, 255)
    sleeper = darken(pal[min(5, pal.len - 1)], 700)
    ballastTint = rgba(0, 0, 0, 56)          ## the 22 % darkening
    platformPaint = rgba(226, 216, 196, 255)
    sidingPaint = rgba(232, 163, 61, 210)
    labelInk = rgba(20, 14, 9, 235)
    labelPaper = rgba(242, 232, 216, 240)
  result = newImage(BoardWidth, BoardHeight)

  # ballast, tiled from the starter's arena floor and darkened
  for y in 0 ..< BoardHeight:
    for x in 0 ..< BoardWidth:
      var c = floorTile[x mod floorTile.width, y mod floorTile.height].rgba()
      c.a = 255
      result[x, y] = c.rgba
  result.fillBox(0, 0, BoardWidth, BoardHeight, ballastTint)

  # the gravel shoulder: the wall texture, heavily darkened, everywhere there
  # is no rail at all, so off-track ground reads as ground and not as a hole
  for y in 0 ..< BoardHeight:
    for x in 0 ..< BoardWidth:
      let cell = (y div CellPx) * map.width + (x div CellPx)
      if map.isRail(cell):
        continue
      var c = shoulder[x mod shoulder.width, y mod shoulder.height].rgba()
      c = darken(c, 420)
      c.a = 255
      result[x, y] = c.rgba

  # rails and sleepers, from the ends rule: two steel rails plus a check rail
  # on every curve, drawn from the centre of the cell out through each end
  for cell in map.railCells:
    let
      cx = map.cellX(cell) * CellPx
      cy = map.cellY(cell) * CellPx
      mid = CellPx div 2
      gauge = 4
    for d in 0 .. 3:
      if not map.hasEnd(cell, Dir(d)):
        continue
      case d
      of 0:                                   ## north
        for y in 0 .. mid:
          for s in [-gauge, gauge]:
            result.plot(cx + mid + s, cy + y, steel)
        var y = 2
        while y < mid:
          result.fillBox(cx + mid - gauge - 2, cy + y, gauge * 2 + 4, 1, sleeper)
          y += 5
      of 2:                                   ## south
        for y in mid ..< CellPx:
          for s in [-gauge, gauge]:
            result.plot(cx + mid + s, cy + y, steel)
        var y = mid + 2
        while y < CellPx:
          result.fillBox(cx + mid - gauge - 2, cy + y, gauge * 2 + 4, 1, sleeper)
          y += 5
      of 1:                                   ## east
        for x in mid ..< CellPx:
          for s in [-gauge, gauge]:
            result.plot(cx + x, cy + mid + s, steel)
        var x = mid + 2
        while x < CellPx:
          result.fillBox(cx + x, cy + mid - gauge - 2, 1, gauge * 2 + 4, sleeper)
          x += 5
      else:                                   ## west
        for x in 0 .. mid:
          for s in [-gauge, gauge]:
            result.plot(cx + x, cy + mid + s, steel)
        var x = 2
        while x < mid:
          result.fillBox(cx + x, cy + mid - gauge - 2, 1, gauge * 2 + 4, sleeper)
          x += 5
    if map.tiles[cell] == '+':
      ## the flat crossing reads as a diamond of bare steel
      for i in 0 ..< CellPx:
        result.plot(cx + i, cy + i, steel)
        result.plot(cx + CellPx - 1 - i, cy + i, steel)

  # platform slabs and station letters
  for station in 0 ..< map.stationCells.len:
    var cells = map.stationCells[station]
    cells.sort()
    for cell in cells:
      let
        cx = map.cellX(cell) * CellPx
        cy = map.cellY(cell) * CellPx
      if map.hasEnd(cell, Dir(1)) or map.hasEnd(cell, Dir(3)):
        result.fillBox(cx, cy + 1, CellPx, 3, platformPaint)
        result.fillBox(cx, cy + CellPx - 4, CellPx, 3, platformPaint)
      else:
        result.fillBox(cx + 1, cy, 3, CellPx, platformPaint)
        result.fillBox(cx + CellPx - 4, cy, 3, CellPx, platformPaint)
    let head = cells[cells.len div 2]
    let
      hx = map.cellX(head) * CellPx
      hy = map.cellY(head) * CellPx
    result.fillBox(hx + 4, hy + 4, 12, 12, labelPaper)
    result.drawTextInto($StationLetters[station], hx + 6, hy + 1, 13, labelInk)

  # siding marks
  for s in 0 ..< SidingIds.len:
    let edge = map.sidingEdge[s]
    if edge < 0:
      continue
    for cell in map.edges[edge].cells:
      let
        cx = map.cellX(cell) * CellPx
        cy = map.cellY(cell) * CellPx
      result.fillBox(cx, cy + CellPx - 2, CellPx, 2, sidingPaint)
    let cells = map.edges[edge].cells
    if cells.len > 0:
      let head = cells[cells.len div 2]
      result.drawTextInto(SidingIds[s], map.cellX(head) * CellPx + 2,
                          map.cellY(head) * CellPx + 8, 9, sidingPaint)

  # named junctions
  for j in 0 ..< JunctionIds.len:
    let cell = map.junctionCell[j]
    if cell < 0:
      continue
    result.drawTextInto(JunctionIds[j], map.cellX(cell) * CellPx + 2,
                        map.cellY(cell) * CellPx - 2, 9,
                        rgba(232, 232, 216, 220))

  bedCache[map.name] = result

# ---------------------------------------------------------------------------
#  Train chips
# ---------------------------------------------------------------------------

proc chipIndex*(seat, speed, facing: int): int {.inline.} =
  ## seat 0..3, speed class 1..4, facing N/E/S/W.
  ((seat * 4) + (speed - 1)) * 4 + facing

proc bakeChips*(): seq[Image] =
  ## 64 locomotive chips: four facings x four speed classes x four seat
  ## colours, each with a lit headlamp and a body whose length reads its
  ## speed class (an express is short and blunt, a freight is long).
  if chipCache.len > 0:
    return chipCache
  let
    colours = seatColours()
    lamp = rgba(255, 236, 168, 255)
    glass = rgba(28, 34, 40, 235)
  for seat in 0 .. 3:
    for speed in 1 .. 4:
      for facing in 0 .. 3:
        let image = newImage(CellPx, CellPx)
        let
          body = colours[seat mod colours.len]
          dark = darken(body, 620)
          length = 8 + speed * 2       ## 10 .. 16 px
          width = 12
          x0 = (CellPx - (if facing in [1, 3]: length else: width)) div 2
          y0 = (CellPx - (if facing in [1, 3]: width else: length)) div 2
          w = if facing in [1, 3]: length else: width
          h = if facing in [1, 3]: width else: length
        image.fillBox(x0, y0, w, h, dark)
        image.fillBox(x0 + 1, y0 + 1, w - 2, h - 2, body)
        ## the cab glass sits at the back, the headlamp at the front
        case facing
        of 0:
          image.fillBox(x0 + 2, y0 + h - 5, w - 4, 3, glass)
          image.fillBox(x0 + 3, y0, w - 6, 2, lamp)
        of 2:
          image.fillBox(x0 + 2, y0 + 2, w - 4, 3, glass)
          image.fillBox(x0 + 3, y0 + h - 2, w - 6, 2, lamp)
        of 1:
          image.fillBox(x0 + 2, y0 + 2, 3, h - 4, glass)
          image.fillBox(x0 + w - 2, y0 + 3, 2, h - 6, lamp)
        else:
          image.fillBox(x0 + w - 5, y0 + 2, 3, h - 4, glass)
          image.fillBox(x0, y0 + 3, 2, h - 6, lamp)
        ## the speed pip: one dot per class, along the flank
        for pip in 0 ..< speed:
          image.fillBox(x0 + 2 + pip * 3, y0 + h div 2, 2, 2,
                        rgba(250, 250, 244, 235))
        chipCache.add(image)
  chipCache

proc bakeOverlays*(): seq[Image] =
  ## 0 held signal, 1 malfunction spanner, 2 deadlock ring, 3 late underline,
  ## 4 interlock tint.
  if overlayCache.len > 0:
    return overlayCache
  let red = rgba(224, 82, 58, 255)
  let amber = rgba(232, 163, 61, 255)

  var held = newImage(CellPx, CellPx)
  held.fillBox(CellPx div 2 - 2, 1, 4, 4, red)
  held.fillBox(CellPx div 2 - 1, 5, 2, 3, rgba(90, 70, 60, 220))
  overlayCache.add(held)

  var broken = newImage(CellPx, CellPx)
  for i in 0 ..< CellPx:
    broken.plot(i, 0, amber)
    broken.plot(i, CellPx - 1, amber)
    broken.plot(0, i, amber)
    broken.plot(CellPx - 1, i, amber)
  broken.fillBox(CellPx div 2 - 4, CellPx div 2 - 1, 8, 3, amber)
  broken.fillBox(CellPx div 2 - 5, CellPx div 2 - 3, 3, 7, amber)
  overlayCache.add(broken)

  var ring = newImage(CellPx, CellPx)
  for i in 0 ..< CellPx:
    for j in 0 ..< CellPx:
      let
        dx = i - CellPx div 2
        dy = j - CellPx div 2
        d2 = dx * dx + dy * dy
      if d2 >= 56 and d2 <= 90:
        ring.plot(i, j, red)
  overlayCache.add(ring)

  var late = newImage(CellPx, CellPx)
  late.fillBox(2, CellPx - 3, CellPx - 4, 2, red)
  overlayCache.add(late)

  var tint = newImage(CellPx, CellPx)
  tint.fillBox(0, 0, CellPx, CellPx, rgba(224, 82, 58, 40))
  overlayCache.add(tint)

  overlayCache

proc rgbaBytes*(image: Image): seq[uint8] =
  ## Straight (un-premultiplied) RGBA, the layout the sprite protocol wants.
  result = newSeq[uint8](image.width * image.height * 4)
  var i = 0
  for y in 0 ..< image.height:
    for x in 0 ..< image.width:
      let c = image[x, y].rgba()
      result[i] = c.r
      result[i + 1] = c.g
      result[i + 2] = c.b
      result[i + 3] = c.a
      i += 4
