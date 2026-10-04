# 0015. Stream elevation as versioned tiles, never waiting on the network

- **Status:** Accepted
- **Date:** 2026-09-08 · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** David Durieux, WarpZone
- **Evidence:** 286d16b8, cc30782a, 6189deda, a7493444, decd5ea2, 67d24570, fbb5d3f2, 873e8bfa,
  0bd6048a, c95e99a4; journal [PLANET_CHUNK_STREAMING.md](../PLANET_CHUNK_STREAMING.md) (French)

## Context

Every build carried 3.9 GB of elevation. Baked meshes would take ~14.5 TB per planet to host
against ~69 GB of tiles. Measured traps: an HTTP lookup on the main thread dropped the client to
0.2 FPS; a server that built collision before its tiles arrived persisted the flat fallback.

## Decision

- Stream the elevation **tiles**, never meshes: one file per fine tile, one `floor.bin` for the
  coarse floor (its 1,020 tiles would cost 1,020 round trips).
- Address by **path**, `<base>/<body>/<data_version>/...`; a published version is immutable and
  the client's tile cache has one folder per version.
- Versions climb the channels `unstable → dev → preprod → prod`: publishing feeds `unstable`,
  promotion moves a manifest one rung (all or nothing, one body at a time, never to a missing
  tree). Client and server read the same manifest and negotiate nothing; both print
  `StreamChannel.fingerprint()`. A version no channel cites is collected (`--gc`).
- Never touch the network from the main thread or a mesh task: a chunk waits until its tiles,
  neighbours included, are resident, on client and server; six worker threads fetch them.
- URL and channel are deployment flags ([0018](0018-settings-and-config-files.md)). Service absent
  or down: the planet reads its local pack and prints a line; it is not an error.

## Consequences

- The main thread asks `presence_of()`; `has_tile()` blocks (download threads only). Never share
  an `HTTPClient` between threads (signal 11). Never build or persist geometry from a missing tile.
- Never change bytes under a published version: publish a new `data_version`, which also keys the
  chunk cache ([0017](0017-bump-chunk-cache-version-on-terrain-change.md)).
- `prod` left on the old version is the rollback: promote it last, collect after. Streaming saves
  no CPU (tile reads were 9.4% of a chunk's generation).

## Rejected alternatives

- **A mesh CDN**, full or bounded (phase 6): any code patch invalidates it and rebuilding needs
  headless Godot workers; with streamed heights a miss simply builds locally.
- **Content addressing**: 1% deduplication on 65,532 tiles, ~580 KB working set, 537 MB manifest.
- **Bundles at every level**: a `tr32` tile is one 4 KiB block already; only the floor gains.
- **A version handshake message**; a "pending" state through the sampler; one thread (38 tiles/s).

## In the code

- `scenes/planet/remote_tile_source.gd`: for_planet (null = local pack), presence_of, workers
- `scenes/planet/tile_residency.gd`: the request_chunk_tiles gate, prefetch, prefetch_chunks
- `scenes/planet/stream_channel.gd`: the ladder, configured_name, resolve, fingerprint
- `scenes/planet/planet_terrain.gd`: initialize opens the source; _server_start_chunk_load gates
- `tools/planettech/publish/`: publish_tiles.py (tree, presence maps, floor), stream_channels.py

## Enforced by

- `test/unit/test_tile_residency.gd` (`test_the_gate_never_touches_the_network`),
  `test/unit/test_remote_tile_source.gd`, `test/unit/test_stream_channel.gd`: CI runs them only in
  the non-blocking "Whole GUT suite" step.
- `test/unit/test_stream_channels_py.py`, `test/unit/test_publish_tiles_py.py`: not run by CI.
