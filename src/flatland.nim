## The flatland game server entrypoint.
##
## Forked from `coworld-ctf`'s `src/ctf.nim`, including the rule that the seed
## is randomised BEFORE `config.update`, so an explicit seed in the runner's
## config still wins and every seed-derived draw follows the FINAL seed.

import flatland/server

when isMainModule:
  main()
