## ONE source for the constants the browser chrome needs. `tools/gen_wire_constants.nim`
## prints this as `window.FLATLAND_WIRE = {...}` into the static bundle, so the
## page can never drift from the engine. Forked from `coworld-ctf`'s
## `src/ctf/wire_constants.nim` (the `window.CTF_WIRE` -> `window.FLATLAND_WIRE`
## rename is the only semantic change).

import std/strutils

import sim_types, upstream, sim_config, railmap, global, rig_art, broadcast

proc wireConstantsJs*(): string =
  # 0.5 is the replay-only half speed (ReplayHalfSpeedIndex, command '5');
  # it rides ahead of the engine's integer PlaybackSpeeds.
  var speeds: seq[string] = @["0.5"]
  for speed in PlaybackSpeeds:
    speeds.add($speed)
  var beats: seq[string]
  for kind in BeatKinds:
    beats.add("\"" & kind & "\"")
  var events: seq[string]
  for kind in DerivedEventKinds:
    events.add("\"" & kind & "\"")
  var teams: seq[string]
  for team in ChromeTeams:
    teams.add("\"" & team & "\"")
  var aliases: seq[string]
  for slot in 0 ..< MaxSeats:
    aliases.add("\"" & seatAlias(slot) & "\"")
  "window.FLATLAND_WIRE={" &
    "\"game\":\"" & GameName & "\"," &
    "\"gameVersion\":\"" & GameVersion & "\"," &
    "\"protocol\":\"" & ProtocolName & "\"," &
    "\"fps\":" & $TargetFps & "," &
    "\"speeds\":[" & speeds.join(",") & "]," &
    "\"chromeSpriteId\":" & $BroadcastChromeSpriteId & "," &
    "\"cellPx\":" & $CellPx & "," &
    "\"boardW\":" & $BoardWidth & "," &
    "\"boardH\":" & $BoardHeight & "," &
    "\"gridW\":" & $GridWidth & "," &
    "\"gridH\":" & $GridHeight & "," &
    "\"maxTicks\":" & $DefaultMaxTicks & "," &
    "\"turnTicks\":" & $DefaultTurnTicks & "," &
    "\"maxSayRunes\":" & $MaxSayRunes & "," &
    "\"maxNoteRunes\":" & $MaxNoteRunes & "," &
    "\"stations\":\"" & StationLetters & "\"," &
    "\"teams\":[" & teams.join(",") & "]," &
    "\"aliases\":[" & aliases.join(",") & "]," &
    "\"beatKinds\":[" & beats.join(",") & "]," &
    "\"eventKinds\":[" & events.join(",") & "]};\n" &
    # `client/chrome_common.js` is copied BYTE-FOR-BYTE from the starter
    # (design note §Viewer -> chrome provenance) and reads its wire constants
    # from `window.CTF_WIRE`. Aliasing here is what lets that file stay
    # byte-identical while the engine-side name is renamed with everything
    # else in the fork.
    "window.CTF_WIRE=window.FLATLAND_WIRE;"
