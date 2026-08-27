## Prints the one-source browser wire constants. `Dockerfile.replay-viewer`
## pipes this into `replay-viewer/dist/wire_constants.js`, which the page and
## the Worker both load before `broadcast_core.js`.
import flatland/wire_constants

when isMainModule:
  echo wireConstantsJs()
