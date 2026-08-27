## The order schema: what a dispatcher (LLM or scripted) may say, how a reply
## is parsed TOLERANTLY, and how an illegal order is REPAIRED instead of
## dropped. Forked from `coworld-ctf`'s `src/ctf/directives.nim`.
##
## Both policy kinds emit the SAME object through the SAME validator, which is
## what makes the bounded-orders test in `tests/test_flatland_driver.nim`
## meaningful.
##
## RUNE DISCIPLINE. Every cap here is measured in RUNES and every truncation
## lands on a rune boundary (`truncateRunes`). Slicing by BYTE index anywhere
## on the path to the replay is forbidden.

import std/[json, strutils, unicode]

import sim_types, railmap

type
  OrderEntry* = object
    train*: int                ## index into the world's train array
    verb*: OrderVerb
    arg*: string
    fromReply*: bool           ## a reply entry really named this train

  DirectiveSource* = enum
    dsLlm = "llm"
    dsScripted = "scripted"
    dsFallback = "fallback"

  Directive* = object
    ## One seat's whole order set for one turn.
    orders*: seq[OrderEntry]
    say*: string
    notes*: string
    source*: DirectiveSource
    latencyMs*: int
    rejected*: int

  DirectiveError* = object of ValueError

  OrderContext* = object
    ## Everything the validator needs about the seat, and nothing else.
    trainIds*: seq[string]     ## this seat's train ids, ascending
    trainIndex*: seq[int]      ## the matching world indices
    arrived*: seq[bool]
    previous*: seq[TrainOrder] ## the order each of those trains currently has
    map*: RailMap
    cap*: int                  ## trainsPerSeat

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(
      DirectiveError, "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc parseVerb*(text: string): tuple[ok: bool, verb: OrderVerb] =
  ## Tolerant: lower-cased, trimmed, hyphens and spaces normalised.
  let key = text.strip().toLowerAscii().replace("-", "_").replace(" ", "_")
    .truncateRunes(MaxVerbRunes)
  for verb in OrderVerb:
    if $verb == key:
      return (true, verb)
  (false, ovRun)

proc defaultDirective*(ctx: OrderContext): Directive =
  ## Every train keeps the order it already has. The floor under every
  ## failure path: no failure mode leaves a train without an order.
  for i in 0 ..< ctx.trainIds.len:
    result.orders.add(OrderEntry(train: ctx.trainIndex[i],
                                 verb: ctx.previous[i].verb,
                                 arg: ctx.previous[i].arg,
                                 fromReply: false))

proc validArg(ctx: OrderContext, verb: OrderVerb, arg: string): bool =
  case verb
  of ovSiding:
    sidingIndex(arg) >= 0
  of ovRoute:
    ctx.map.goalCellsFor(arg).len > 0
  else:
    true

proc parseDirective*(node: JsonNode, ctx: OrderContext): Directive =
  ## Applies the reply to the seat's standing orders. Design §Reply schema:
  ##   * a train not named KEEPS the order it had;
  ##   * an order whose fields do not validate is REPAIRED to that train's
  ##     previous order, never dropped into "no order", and counted;
  ##   * orders naming a train the seat does not own, or one that has already
  ##     arrived, are dropped and counted;
  ##   * entries past `trainsPerSeat` are dropped and counted;
  ##   * a reply with a valid `say` but no `orders` is USABLE.
  if node.isNil or node.kind != JObject:
    raise newException(DirectiveError, "reply is not a JSON object")
  result = defaultDirective(ctx)
  result.say = sanitizeSay(node{"say"}.getStr())
  result.notes = sanitizeNote(node{"notes"}.getStr())

  let orders = node{"orders"}
  if orders.isNil or orders.kind != JArray:
    return
  var taken = 0
  var named = newSeq[bool](ctx.trainIds.len)
  for entry in orders:
    if taken >= ctx.cap:
      inc result.rejected
      continue
    if entry.kind != JObject:
      inc result.rejected
      continue
    let id = entry{"train"}.getStr().strip().toUpperAscii()
      .truncateRunes(MaxTrainIdRunes)
    var slot = -1
    for i, own in ctx.trainIds:
      if own == id:
        slot = i
        break
    if slot < 0 or ctx.arrived[slot] or named[slot]:
      inc result.rejected
      continue
    named[slot] = true
    inc taken
    let parsed = parseVerb(entry{"verb"}.getStr())
    if not parsed.ok:
      inc result.rejected
      continue                              ## repaired: keeps its previous order
    var arg = ""
    if parsed.verb == ovSiding:
      arg = entry{"at"}.getStr().strip().toUpperAscii()
        .truncateRunes(MaxNodeIdRunes)
    elif parsed.verb == ovRoute:
      arg = entry{"via"}.getStr().strip().toUpperAscii()
        .truncateRunes(MaxNodeIdRunes)
    if not ctx.validArg(parsed.verb, arg):
      inc result.rejected
      continue                              ## repaired: keeps its previous order
    result.orders[slot] = OrderEntry(train: ctx.trainIndex[slot],
                                     verb: parsed.verb, arg: arg,
                                     fromReply: true)

proc serialise*(directive: Directive, ids: openArray[string]): JsonNode =
  ## The `directive` replay record's `orders` array.
  result = newJArray()
  for i, order in directive.orders:
    result.add(%*{
      "train": (if i < ids.len: ids[i] else: ""),
      "verb": $order.verb,
      "arg": order.arg
    })
