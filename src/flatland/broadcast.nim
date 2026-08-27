## The broadcast layer: the derived event stream and the chrome frame the
## inherited `client/broadcast_core.js` + `client/chrome_common.js` read.
## Forked from `coworld-ctf`'s `src/ctf/broadcast.nim` — retargeted fields,
## same structure, so the starter's chrome renders this game with no edits and
## the appended FLATLAND block only has to add what is new.
##
## The four seats occupy the chrome's four colour slots (Alpha red, Beta blue,
## Gamma green, Delta yellow), and each slot's `lives` field carries that
## seat's ON-TIME count — which is what makes the inherited momentum graph
## draw the on-time race with no changes to `chrome_common.js`.

import std/[json, strutils]

import sim, replay_runtime, sim_types

const
  ChromeTeams*: array[4, string] = ["red", "blue", "green", "yellow"]
  PlaybackSpeeds*: array[6, int] = [1, 2, 3, 4, 8, 16]

  DerivedEventKinds*: array[13, string] = [
    "turn", "order", "say", "fallback", "depart", "arrive", "malfunction",
    "repaired", "jam", "jamclear", "deadlock", "deadlockclear", "end"
  ]
  BeatKinds*: array[5, string] = [
    "arrival", "malfunction", "deadlock", "fallback", "end"
  ]

proc chromeTeam*(slot: int): string =
  if slot >= 0 and slot < ChromeTeams.len: ChromeTeams[slot] else: "red"

proc stepEvents*(game: SimServer): JsonNode =
  ## Derives the broadcast events from this tick's state deltas, so they cost
  ## no replay bytes and are identical live and in replay. A CLOSED enum: this
  ## proc emits nothing outside `DerivedEventKinds`, and
  ## `tests/test_flatland_events.nim` asserts it.
  result = newJArray()
  for event in game.frameEvents:
    case event.kind
    of Depart:
      result.add(%*{"k": "depart", "train": trainId(event.train),
                    "slot": event.slot,
                    "cell": [game.map.cellX(event.cell), game.map.cellY(event.cell)],
                    "station": (if event.station >= 0:
                                  $StationLetters[event.station] else: "")})
    of Arrive:
      result.add(%*{"k": "arrive", "train": trainId(event.train),
                    "slot": event.slot,
                    "station": $StationLetters[event.station],
                    "tick": event.tick, "onTime": event.cell == 1,
                    "lateness": event.amount, "total": game.arrivedTotal})
    of Malfunction:
      result.add(%*{"k": "malfunction", "train": trainId(event.train),
                    "cell": [game.map.cellX(event.cell), game.map.cellY(event.cell)],
                    "duration": event.amount})
    of Repaired:
      result.add(%*{"k": "repaired", "train": trainId(event.train),
                    "cell": [game.map.cellX(event.cell), game.map.cellY(event.cell)]})
    of Jam, JamClear, Deadlock, DeadlockClear:
      var ids = newJArray()
      var cells = newJArray()
      for train in event.trains:
        ids.add(%trainId(train))
        if game.trains[train].cell >= 0:
          cells.add(%[game.map.cellX(game.trains[train].cell),
                      game.map.cellY(game.trains[train].cell)])
      let kind = case event.kind
        of Jam: "jam"
        of JamClear: "jamclear"
        of Deadlock: "deadlock"
        else: "deadlockclear"
      result.add(%*{"k": kind, "trains": ids, "cells": cells,
                    "tick": event.tick, "ticks": event.amount})
    of PhaseChange:
      if game.phase == GameOver:
        result.add(%*{"k": "end", "reason": $game.reason,
                      "endRule": $game.endRule,
                      "fleetOnTime": game.fleetOnTime,
                      "arrivedTotal": game.arrivedTotal,
                      "par": game.config.parOnTime})
    else:
      discard

proc turnEvents*(game: SimServer, turn: int,
                 records: openArray[JsonNode]): JsonNode =
  ## The turn-boundary events: the turn marker, one `order` per accepted
  ## order, the radio `say` lines and any `fallback`. These are derived from
  ## the replay's chat records, so they are identical live and in replay.
  result = newJArray()
  result.add(%*{"k": "turn", "n": turn})
  for record in records:
    case record{"k"}.getStr()
    of "directive":
      let slot = record{"slot"}.getInt()
      for order in record{"orders"}:
        result.add(%*{"k": "order", "slot": slot,
                      "train": order{"train"}.getStr(),
                      "verb": order{"verb"}.getStr(),
                      "arg": order{"arg"}.getStr()})
      let say = record{"say"}.getStr()
      if say.len > 0:
        result.add(%*{"k": "say", "slot": slot, "text": say})
    of "fallback":
      result.add(%*{"k": "fallback", "slot": record{"slot"}.getInt(),
                    "cause": record{"cause"}.getStr()})
    else:
      discard

proc rosterJson*(game: SimServer): JsonNode =
  ## One row per seat. `name` is the REAL policy name — spectator side only,
  ## never in an observation — and `alias` is the in-game name space.
  result = newJArray()
  for slot in 0 ..< game.seatCount():
    result.add(%*{
      "s": slot,
      "name": game.seats[slot].name,
      "alias": seatAlias(slot),
      "pol": game.seats[slot].policyLabel,
      "kind": game.seats[slot].kind,
      "team": chromeTeam(slot),
      "alive": not game.seats[slot].dead,
      "fb": game.seats[slot].fallbackTurns
    })

proc teamsJson*(game: SimServer): JsonNode =
  ## The chrome's four colour slots. `lives` carries the seat's ON-TIME count,
  ## which is the number the inherited scorebug numeral and momentum graph
  ## already know how to draw.
  result = newJObject()
  for slot in 0 ..< game.seatCount():
    var trains = newJArray()
    for i in game.seatTrains(slot):
      trains.add(%*{
        "id": trainId(i),
        "state": $game.trains[i].state,
        "late": game.trains[i].lateness
      })
    result[chromeTeam(slot)] = %*{
      "lives": game.onTime[slot],
      "prog": game.arrived[slot],
      "onTime": game.onTime[slot],
      "arrived": game.arrived[slot],
      "late": game.latenessTicks[slot],
      "fleet": game.config.trainsPerSeat,
      "alias": seatAlias(slot),
      "policies": %[game.seats[slot].policyLabel],
      "fallbacks": game.seats[slot].fallbackTurns,
      "trains": trains
    }

proc trainsJson*(game: SimServer): JsonNode =
  result = newJArray()
  for i, train in game.trains:
    result.add(%*{
      "id": trainId(i),
      "slot": train.owner,
      "state": $train.state,
      "cell": (if train.cell >= 0:
                 %[game.map.cellX(train.cell), game.map.cellY(train.cell)]
               else: newJNull()),
      "heading": dirName(train.heading),
      "spd": train.ticksPerCell,
      "target": $StationLetters[train.target],
      "late": max(0, game.tick - train.scheduledArrival),
      "mal": train.malfunctionLeft
    })

proc beatsJson*(prescan: Prescan): JsonNode =
  result = newJArray()
  for beat in prescan.beats:
    result.add(%*{"t": beat.tick, "k": beat.kind, "slot": beat.slot,
                  "label": beat.label})

proc lullsJson*(prescan: Prescan): JsonNode =
  result = newJArray()
  for span in prescan.lullSpans:
    result.add(%*[span[0], span[1]])

proc spansJson(spans: seq[array[2, int]]): JsonNode =
  result = newJArray()
  for span in spans:
    result.add(%*[span[0], span[1]])

proc leadJson*(game: SimServer, prescan: Prescan): JsonNode =
  ## The full-timeline series the momentum graph draws at full width on the
  ## first frame: cumulative arrivals and cumulative ON-TIME arrivals.
  var teams = newJArray()
  teams.add(%"arrived")
  teams.add(%"onTime")
  var pts = newJArray()
  var lastArrived = -1
  var lastOnTime = -1
  for tick in 0 ..< prescan.arrivals.len:
    if prescan.arrivals[tick] == lastArrived and
        prescan.onTime[tick] == lastOnTime:
      continue
    lastArrived = prescan.arrivals[tick]
    lastOnTime = prescan.onTime[tick]
    pts.add(%*[tick, lastArrived, lastOnTime])
  %*{"teams": teams, "pts": pts}

proc buildStateJson*(game: SimServer, events: JsonNode, playing: bool,
                     speed, maxTick, startTick: int, looping, transportEnabled,
                     skipLulls, fastForwarding: bool, mismatchTick: int,
                     prescan: Prescan, includeTimeline: bool): string =
  ## The broadcast chrome frame. Board-derived STATE is always present, so a
  ## frame reached by a seek still hydrates the scorebug and the end card with
  ## no events at all.
  var state = %*{
    "t": game.tick,
    "mt": game.config.maxTicks,
    "ph": toLowerAscii($game.phase),
    "lob": game.lobbyTicks div TargetFps,
    "pl": playing,
    "sp": speed,
    "mx": maxTick,
    "st": startTick,
    "lp": looping,
    "sk": skipLulls,
    "ff": fastForwarding,
    "en": transportEnabled,
    "mm": mismatchTick,
    "bs": 1,
    "pov": -1,
    "teams": game.teamsJson(),
    "roster": game.rosterJson(),
    "events": (if events.isNil: newJArray() else: events),
    # --- flatland additions the appended game block reads -------------------
    "turnTicks": game.config.turnTicks,
    "turn": (if game.config.turnTicks > 0:
               (game.tick div game.config.turnTicks) + 1 else: 1),
    "turns": game.config.turnsPerEpisode(),
    "network": game.network,
    "cellPx": 20,
    "arrived": game.arrivedTotal,
    "onTime": game.fleetOnTime,
    "par": game.config.parOnTime,
    "fleet": game.trains.len,
    "malfunctions": game.malfunctions,
    "broken": 0,
    "deadlockTicks": game.deadlockTicks,
    "jams": game.jams,
    "deadlocks": game.deadlocks,
    "trains": game.trainsJson()
  }
  var broken = 0
  for train in game.trains:
    if train.state == tsMalfunctioning:
      inc broken
  state["broken"] = %broken
  var jam = newJArray()
  for train in game.activeJam:
    jam.add(%trainId(train))
  state["jam"] = jam
  var deadlock = newJArray()
  for train in game.activeDeadlock:
    deadlock.add(%trainId(train))
  state["deadlock"] = deadlock
  var deadlockCells = newJArray()
  for cell in game.deadlockCells:
    deadlockCells.add(%[game.map.cellX(cell), game.map.cellY(cell)])
  state["deadlockCells"] = deadlockCells
  state["deadlockSince"] = %game.deadlockStartTick

  if game.feedDirectives.len > 0:
    var records = newJArray()
    for record in game.feedDirectives:
      try:
        records.add(parseJson(record))
      except CatchableError:
        discard
    state["directives"] = records

  if includeTimeline:
    state["lead"] = leadJson(game, prescan)
    state["beats"] = beatsJson(prescan)
    state["lulls"] = lullsJson(prescan)
    state["jamSpans"] = spansJson(prescan.jamSpans)
    state["deadlockSpans"] = spansJson(prescan.deadlockSpans)

  if game.phase == GameOver:
    var seats = newJObject()
    for slot in 0 ..< game.seatCount():
      seats[chromeTeam(slot)] = %*{
        "lives": game.onTime[slot],
        "prog": game.arrived[slot]
      }
    # `winner` is empty and `draw` is false on purpose: a cooperative episode
    # has no winner, so the inherited verdict chip stays off and the appended
    # game block writes the par headline instead.
    state["over"] = %*{
      "winner": "",
      "draw": false,
      "timeLimit": game.endRule == erTickCap,
      "teams": seats,
      "reason": $game.reason,
      "endRule": $game.endRule,
      "fleetOnTime": game.fleetOnTime,
      "arrivedTotal": game.arrivedTotal,
      "par": game.config.parOnTime,
      "deadlocks": game.deadlocks,
      "jams": game.jams,
      "malfunctions": game.malfunctions,
      "jamTicks": game.jamTicks,
      "score": game.scoreFor(0)
    }
  $state
