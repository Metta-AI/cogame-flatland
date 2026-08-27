## The binary `COWLDFLT` replay codec: header, resolved config JSON, then the
## record stream — joins, per-turn ORDER records (the only inputs this game
## has), chat records and one `gameHash` per tick.
##
## Forked from `coworld-ctf`'s `src/ctf/replays.nim`; the magic and the game
## name are the only semantic changes. The bytes are SELF-SUFFICIENT: names,
## aliases, policy kinds, the whole config, the seed, the network name, every
## order and the result document are all in here, so the static wasm viewer
## contacts nothing but S3 for the file.

import std/[json, strutils]

import sim_types

const
  FlatlandReplayMagic* = "COWLDFLT"
  ReplayFormatVersion* = 1'u16

type
  ReplayRecordKind* = enum
    rrEnd = 0
    rrJoin = 1
    rrLeave = 2
    rrOrders = 3
    rrChat = 4
    rrHash = 5
    rrStop = 6

  ReplayOrder* = object
    train*: int
    verb*: OrderVerb
    arg*: string

  ReplayRecord* = object
    kind*: ReplayRecordKind
    slot*: int
    turn*: int
    tick*: int
    hash*: uint64
    name*: string
    token*: string
    text*: string
    endRule*: EndRule
    orders*: seq[ReplayOrder]

  ReplayData* = object
    gameName*: string
    gameVersion*: string
    configJson*: string
    records*: seq[ReplayRecord]

  ReplayWriter* = object
    buffer*: string

  ReplayError* = object of CatchableError

# ---------------------------------------------------------------------------
#  Little-endian primitives
# ---------------------------------------------------------------------------

proc addU8(buffer: var string, value: int) =
  buffer.add(char(value and 0xFF))

proc addU16(buffer: var string, value: int) =
  buffer.add(char(value and 0xFF))
  buffer.add(char((value shr 8) and 0xFF))

proc addU32(buffer: var string, value: int) =
  for shift in [0, 8, 16, 24]:
    buffer.add(char((value shr shift) and 0xFF))

proc addU64(buffer: var string, value: uint64) =
  for shift in 0 .. 7:
    buffer.add(char(int((value shr (shift * 8)) and 0xFF'u64)))

proc addStr(buffer: var string, value: string) =
  buffer.addU32(value.len)
  buffer.add(value)

type Cursor = object
  data: string
  pos: int

proc need(cursor: var Cursor, count: int) =
  if cursor.pos + count > cursor.data.len:
    raise newException(ReplayError, "replay is truncated")

proc readU8(cursor: var Cursor): int =
  cursor.need(1)
  result = int(uint8(cursor.data[cursor.pos]))
  inc cursor.pos

proc readU16(cursor: var Cursor): int =
  cursor.need(2)
  result = int(uint8(cursor.data[cursor.pos])) or
    (int(uint8(cursor.data[cursor.pos + 1])) shl 8)
  cursor.pos += 2

proc readU32(cursor: var Cursor): int =
  cursor.need(4)
  for shift in [0, 8, 16, 24]:
    result = result or (int(uint8(cursor.data[cursor.pos])) shl shift)
    inc cursor.pos

proc readU64(cursor: var Cursor): uint64 =
  cursor.need(8)
  for shift in 0 .. 7:
    result = result or (uint64(uint8(cursor.data[cursor.pos])) shl (shift * 8))
    inc cursor.pos

proc readStr(cursor: var Cursor): string =
  let length = cursor.readU32()
  cursor.need(length)
  result = cursor.data[cursor.pos ..< cursor.pos + length]
  cursor.pos += length

# ---------------------------------------------------------------------------
#  Writing
# ---------------------------------------------------------------------------

proc initReplayWriter*(configJson: string): ReplayWriter =
  result.buffer = FlatlandReplayMagic
  result.buffer.addU16(int(ReplayFormatVersion))
  result.buffer.addStr(GameName)
  result.buffer.addStr(GameVersion)
  result.buffer.addStr(configJson)

proc writeJoin*(writer: var ReplayWriter, slot: int, name, token: string) =
  writer.buffer.addU8(ord(rrJoin))
  writer.buffer.addU8(slot)
  writer.buffer.addStr(name)
  writer.buffer.addStr(token)

proc writeLeave*(writer: var ReplayWriter, slot: int) =
  writer.buffer.addU8(ord(rrLeave))
  writer.buffer.addU8(slot)

proc writeOrders*(writer: var ReplayWriter, turn, slot: int,
                  orders: openArray[ReplayOrder]) =
  writer.buffer.addU8(ord(rrOrders))
  writer.buffer.addU16(turn)
  writer.buffer.addU8(slot)
  writer.buffer.addU8(orders.len)
  for order in orders:
    writer.buffer.addU8(order.train)
    writer.buffer.addU8(ord(order.verb))
    writer.buffer.addStr(order.arg)

proc writeChat*(writer: var ReplayWriter, text: string) =
  writer.buffer.addU8(ord(rrChat))
  writer.buffer.addStr(text)

proc writeHash*(writer: var ReplayWriter, tick: int, hash: uint64) =
  writer.buffer.addU8(ord(rrHash))
  writer.buffer.addU16(tick)
  writer.buffer.addU64(hash)

proc writeStop*(writer: var ReplayWriter, tick: int, rule: EndRule) =
  ## The load-bearing wall-clock / fault stop. A wall-clock fact cannot be
  ## re-derived from sim state, so it is recorded and applied by the same proc
  ## on record and on playback (the particle-worlds 2026-08-26 scar).
  writer.buffer.addU8(ord(rrStop))
  writer.buffer.addU16(tick)
  writer.buffer.addU8(ord(rule))

proc finish*(writer: var ReplayWriter): string =
  writer.buffer.addU8(ord(rrEnd))
  writer.buffer

# ---------------------------------------------------------------------------
#  Reading
# ---------------------------------------------------------------------------

proc parseReplayBytes*(data: string): ReplayData =
  if data.len < FlatlandReplayMagic.len or
      data[0 ..< FlatlandReplayMagic.len] != FlatlandReplayMagic:
    raise newException(ReplayError, "not a " & FlatlandReplayMagic & " replay")
  var cursor = Cursor(data: data, pos: FlatlandReplayMagic.len)
  let format = cursor.readU16()
  if format != int(ReplayFormatVersion):
    raise newException(ReplayError, "unsupported replay format " & $format)
  result.gameName = cursor.readStr()
  result.gameVersion = cursor.readStr()
  result.configJson = cursor.readStr()
  while true:
    let kind = cursor.readU8()
    case ReplayRecordKind(kind)
    of rrEnd:
      break
    of rrJoin:
      var record = ReplayRecord(kind: rrJoin)
      record.slot = cursor.readU8()
      record.name = cursor.readStr()
      record.token = cursor.readStr()
      result.records.add(record)
    of rrLeave:
      var record = ReplayRecord(kind: rrLeave)
      record.slot = cursor.readU8()
      result.records.add(record)
    of rrOrders:
      var record = ReplayRecord(kind: rrOrders)
      record.turn = cursor.readU16()
      record.slot = cursor.readU8()
      let count = cursor.readU8()
      for _ in 0 ..< count:
        var order = ReplayOrder()
        order.train = cursor.readU8()
        order.verb = OrderVerb(cursor.readU8())
        order.arg = cursor.readStr()
        record.orders.add(order)
      result.records.add(record)
    of rrChat:
      var record = ReplayRecord(kind: rrChat)
      record.text = cursor.readStr()
      result.records.add(record)
    of rrHash:
      var record = ReplayRecord(kind: rrHash)
      record.tick = cursor.readU16()
      record.hash = cursor.readU64()
      result.records.add(record)
    of rrStop:
      var record = ReplayRecord(kind: rrStop)
      record.tick = cursor.readU16()
      record.endRule = EndRule(cursor.readU8())
      result.records.add(record)

proc configNode*(replay: ReplayData): JsonNode =
  try:
    parseJson(replay.configJson)
  except CatchableError:
    newJObject()

proc seatNames*(replay: ReplayData): seq[string] =
  let node = replay.configNode()
  let players = node{"players"}
  if not players.isNil and players.kind == JArray:
    for entry in players:
      result.add(entry{"name"}.getStr())
  for record in replay.records:
    if record.kind != rrJoin or record.name.len == 0:
      continue
    while result.len <= record.slot:
      result.add("")
    result[record.slot] = record.name

proc chatRecords*(replay: ReplayData): seq[JsonNode] =
  for record in replay.records:
    if record.kind != rrChat:
      continue
    try:
      result.add(parseJson(record.text))
    except CatchableError:
      discard

proc resultDocument*(replay: ReplayData): JsonNode =
  result = newJObject()
  for node in replay.chatRecords():
    if node{"k"}.getStr() == "result":
      let doc = node{"results"}
      if not doc.isNil:
        return doc

proc tickCount*(replay: ReplayData): int =
  for record in replay.records:
    if record.kind == rrHash:
      result = max(result, record.tick)

proc describe*(replay: ReplayData): string =
  "COWLDFLT " & replay.gameName & " v" & replay.gameVersion & " (" &
    $replay.records.len & " records, " & $replay.tickCount() & " ticks)"
