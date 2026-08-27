## Every constant this fork borrows from upstream Flatland, with the citation
## beside it. `tests/test_flatland_upstream.nim` asserts the shipped values
## still equal the table at the head of the design note; a constant edited
## without editing its citation fails the build.
##
## Upstream: `flatland-association/flatland-rl` (`flatland.envs.rail_env`).
## This repo reproduces the RULES IDIOM, not a bit-exact port — every
## divergence is named in `docs/PORTING-FLATLAND.md`.

import sim_types

const
  # Action space -- flatland docs, "Observation and Action Spaces":
  #   0 do nothing, 1 deviate left, 2 go forward, 3 deviate right, 4 stop.
  ActionDoNothing* = 0
  ActionMoveLeft* = 1
  ActionMoveForward* = 2
  ActionMoveRight* = 3
  ActionStopMoving* = 4

  # Orientation enum -- flatland specifications, "Railway Specifications":
  #   North up, East right, South down, West left.
  DirNorth* = 0
  DirEast* = 1
  DirSouth* = 2
  DirWest* = 3

  # Neighbourhood -- same source: 4-connected, the grid does NOT wrap.
  Connectivity* = 4
  GridWraps* = false

  # Cell exclusivity -- flatland specifications: "each cell is exclusive and
  # can only be occupied by one agent at any given time".
  CellsAreExclusive* = true

  # Dead end -- `rail_env` module docs: moving forward in a dead-end cell
  # turns the train 180 degrees and steps back the way it came.
  DeadEndReverses* = true

  # Move order -- `rail_env` module docs: "the actions of the agents are
  # executed in order of their handle".
  MoveOrderIsByHandle* = true

  # Malfunctions -- flatland FAQ, "Flatland Environment" + the 2.0 tutorial:
  # a Poisson process parameterised by rate/min/max; a malfunctioning train
  # cannot act and blocks the paths of others; nothing repairs it early.
  MalfunctionsBlockOthers* = true
  MalfunctionsCannotBeRepairedEarly* = true

  # Speeds -- flatland 2.0 tutorial: fastest speed is 1, slower speeds lie in
  # (0, 1), no more than 5 speed profiles. Here they are the reciprocal
  # integers `ticksPerCell` (divergence 3).
  MaxSpeedProfiles* = 5
  SpeedClasses*: array[4, int] = [1, 2, 3, 4]

  # Removal at target -- `RailEnv` signature: `remove_agents_at_target = True`.
  RemoveAgentsAtTarget* = true

  # Episode length -- flatland FAQ: `max_time_steps = 4 * 2 * (width + height + 20)`.
  EpisodeLengthWidthCoefficient* = 8
  EpisodeLengthConstant* = 20

proc upstreamMaxTimeSteps*(width, height: int): int =
  ## `4 * 2 * (width + height + 20)`, upstream's own formula. For the shipped
  ## 28 x 14 board that is `8 * 62 = 496`.
  EpisodeLengthWidthCoefficient * (width + height + EpisodeLengthConstant)

const
  DefaultMaxTicks* = upstreamMaxTimeSteps(GridWidth, GridHeight)  ## 496

static:
  doAssert DefaultMaxTicks == 496
  doAssert ActionDoNothing == ord(acDoNothing)
  doAssert ActionMoveLeft == ord(acMoveLeft)
  doAssert ActionMoveForward == ord(acMoveForward)
  doAssert ActionMoveRight == ord(acMoveRight)
  doAssert ActionStopMoving == ord(acStop)
