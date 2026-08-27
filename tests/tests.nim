## The whole suite, in the starter's four balanced shards.
##
##   nim c -r tests/tests.nim
##
## `ci.yml` runs every `tests/*.nim` in debug AND in -d:release, so each suite
## also runs on its own; this entry point is the one to use locally.
import ./shard_1
import ./shard_2
import ./shard_3
import ./shard_4
