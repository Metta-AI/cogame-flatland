## The tier-2 event WIRE FORMAT (`COGAME_EVENTS_URI`), shared by live emission
## and re-simulation. Forked from `coworld-ctf`'s `src/ctf/events.nim`: the
## `SimEventKind` set is this game's, the row shape and the mandatory trailing
## summary row are the starter's.
##
## `SimEvent` never enters `gameHash`, so nothing here can affect determinism.

import std/json

import sim

proc key*(kind: SimEventKind): string =
  ## The JSON event key for one tier-2 event kind.
  case kind
  of Depart: "depart"
  of Arrive: "arrive"
  of Malfunction: "malfunction"
  of Repaired: "repaired"
  of Blocked: "blocked"
  of Jam: "jam"
  of JamClear: "jam_clear"
  of Deadlock: "deadlock"
  of DeadlockClear: "deadlock_clear"
  of TurnStart: "turn_start"
  of DirectiveIssued: "directive"
  of FallbackTaken: "fallback"
  of PhaseChange: "phase"

proc jsonRow*(event: SimEvent): JsonNode =
  result = newJObject()
  result["tick"] = %event.tick
  result["kind"] = %event.kind.key()
  result["train"] = %event.train
  result["slot"] = %event.slot
  result["cell"] = %event.cell
  result["amount"] = %event.amount
  result["station"] = %event.station
  result["content"] = %event.content
  var trains = newJArray()
  for train in event.trains:
    trains.add(%train)
  result["trains"] = trains

proc eventsJsonl*(events: openArray[SimEvent], ticks: int,
                  summaryExtra: JsonNode = nil): string =
  ## One JSON-lines row per event, then a summary.
  ##
  ## The trailing summary row is part of the CONTRACT, not decoration — it is
  ## how a reader distinguishes "this episode had no events" from "the file
  ## was truncated", and it carries the GameVersion the events were produced
  ## under so a consumer never has to infer it.
  var lines = newSeqOfCap[string](events.len + 1)
  for event in events:
    lines.add($event.jsonRow())
  var summary = newJObject()
  summary["type"] = %"summary"
  summary["ticks"] = %ticks
  summary["events"] = %events.len
  summary["gameVersion"] = %GameVersion
  if summaryExtra != nil:
    for key, value in summaryExtra:
      summary[key] = value
  lines.add($summary)
  result = ""
  for line in lines:
    result.add(line)
    result.add('\n')
