# 0017. Change the chunk cache key whenever baked terrain output changes

- **Status:** Accepted
- **Date:** 2026-09-08 · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** David Durieux
- **Evidence:** a21f655c, d23be211 (#263), 46f25d0e, e7f246af; the bumps v26 → v58, 8c94e11a to
  7674377d (`git log -G 'tr%d_v[0-9]+' -- scenes/planet/planet_terrain.gd`)

## Context

Chunk meshes (client) and collision shapes (server) cost hundreds of milliseconds each, so they
are cached on disk under a key kept in each planet's `version.txt`; a new key wipes that cache at
load. The old key held five export fields a re-export leaves alone: "Cache valid" then served the
previous terrain for good, which looked like a failed export.

## Decision

The key is `_cache_version`, built in `PlanetTerrain.initialize()`. Anything that changes what a
chunk bakes (heights, vertices, colours, collision faces, materials copied into a mesh) changes it:

- **Exported elevation**: the `_dv` fragment, the pack's `data_version`, a fingerprint of the
  export's inputs. An exporter algorithm change that moves no constant bumps `ALGO_VERSION` there.
- **Data and tunables with a fingerprint**: their own fragment (`_cor`, `_brg`, `_rw`, `_pz`, `_mt`,
  `_vr`, `_lv`, `_fm`, `_sk`, `_rk`), empty where unused so other planets keep their key.
- **Runtime code no field captures**: bump the `vNN` literal (v58 today) in both format strings,
  the key and `relief_signature`, and add a `vNN → vNN+1` comment line saying what changed.
- **Server collision only**: bump the server suffix (`_colrel1_colbf2_grid8k`).

## Consequences

- A bump re-bakes every chunk on every machine at its next load and voids the pad altitudes that
  buildings persisted (`relief_signature`). That cost is accepted; stale terrain is not.
- Must not: change baked output without changing the key; rename a fragment for nothing (it re-keys
  every planet); put runtime state in the key: a chunk under a terrain pad stays out of the cache.
- Output kept bit-identical (a C# twin, [0016](0016-csharp-twins-match-gdscript-bit-for-bit.md))
  needs no bump. The same `data_version` names the streamed tile version
  ([0015](0015-stream-elevation-as-versioned-tiles.md)).

## Rejected alternatives

- **The five export fields alone** (name, radius, max height, offset, tile_res): blind to a
  re-export that redraws every elevation.
- **Hashing the produced pack**: its manifest is written in the header, before the tiles. A manual
  `vNN` bump for exporter changes was what `_dv` replaced.
- **Live pads in the key**: every building spawn would throw away the whole planet's cache.
- **The load-time check alone** (`_cached_geom_valid`): sized for the 3-6 km fallback error.

## In the code

- `scenes/planet/planet_terrain.gd`: initialize builds the key; the comment above is the history
- `scenes/planet/chunk_disk_cache.gd`: _validate_version wipes a planet's cache on a new key
- `scenes/planet/planet_data.gd`: chunk_data_version, the fingerprints, chunk_cache_ineligible
- `tools/planettech/qgis/export_elevation.py`: compute_data_version and ALGO_VERSION
- `scenes/planet/volcano_relief.gd`: ALGO_VERSION, the "_vr" fragment

## Enforced by

Nothing yet. `ChunkDiskCache` compares keys at run time, but no test fails when terrain output
changes without a new key.
