# QGIS Tools for StarDeception — Quick Start

This folder contains the QGIS ↔ Godot pipeline scripts for designing and importing planet data.

> **Full documentation**: see [`docs/QGIS_PLANET_WORKFLOW.md`](../../docs/QGIS_PLANET_WORKFLOW.md) for the complete step-by-step QGIS guide (layer creation, styling, coordinate system explanation, etc.).

---

## Files Overview

| File | Runs In | Purpose |
|---|---|---|
| `setup_planet_project.py` | QGIS Python Console | Creates/refreshes a planet's QGIS project + PostGIS schema. Interactive: asks the planet name/radius, then which layers (and which per-planet values, e.g. rock types) to create. |
| `layers/` | library | **Where the layers are defined.** One small declarative module per category (`layers/biomes/forest.py`, `layers/roads.py`…); `layers/core.py` is the PostGIS plumbing, `layers/dialog.py` the picker. See "Layer definitions" below. |
| `export_elevation.py` | QGIS Python Console | **Elevation-only**: builds the whole height pyramid into a single `heights.pack`. Documented at [Elevation — from contours to a pack](https://developper.dyingstar-game.com/docs/planetTech/elevation_export). |
| `export_poi.py` | QGIS Python Console | **POI-only**: flattens the `poi` point layer to `<planet>_poi.json`, read back by the `PlanetTerrain` inspector button. See below. |
| `export_roads.py` | QGIS Python Console | **Roads-only**: writes `parts/roads.dsmpart` (per chunk, per LOD) and relinks `terrainmodifier.pack`; also still writes the legacy `<planet>_roads_buffered.json`. See below. |
| `export_biomes.py` | QGIS Python Console | **Regions-only**: every Polygon biome layer → `parts/biomes.dsmpart` (POPULATE records per tile, n1…export_nside) and relinks the pack; refreshes `rocks.json`. See below. |
| `export_rocks.py` | QGIS console or `python3` | Writes the rock catalogue (`layers/rocks.py`) to `assets/_universe/_shared/materials/rocks.json`, read by `RockCatalogue` in Godot. |
| `export/planet/biomes.py` | library | The POPULATE part builder: tiling, full / partial coverage, overlap order. |
| `link_modifiers.py` | QGIS console or `python3` | Reassembles `terrainmodifier.pack` from every `parts/*.dsmpart`. Called automatically by each exporter; `--explode` does the reverse. See below. |
| `export/planet/dsmp.py` | library | Authoritative DSMP/DSMQ format spec + encoder. No QGIS import, unit-testable with plain `python3`. |
| `export/planet/modifier_geom.py` | library | Tile assignment, clipping, decimation. Holds the road **partition** that makes double-rendering impossible. |
| `export/planet/dsmp_strings.py` | library | The append-only `parts/strings.json` intern table. |
| `export/planet/roads.py` | library | Road widths (the single Python mirror of `RoadTerrain.HALF_WIDTH_M`) and the ROAD part builder. |
| `export_planet_old.py` | QGIS Python Console | **Retired** full pipeline (biome GeoJSON, spatial tiles, `.planetpack` recipes). Kept for reference; its outputs are no longer read at runtime. |

---

## Elevation pipeline (`export_elevation.py`)

Documented in full on the technical docs site:

- [Elevation — from contours to a pack](https://developper.dyingstar-game.com/docs/planetTech/elevation_export)
  — drawing contours, choosing the tiling, sparse pruning, what the pack contains.
- [Publishing tiles & promoting versions](https://developper.dyingstar-game.com/docs/planetTech/publication_channels)
  — turning the pack into tiles served over HTTP, and the version channels.
- [How the game reads elevation](https://developper.dyingstar-game.com/docs/planetTech/elevation_runtime)
  — client, server and editor.

Short version: run it from the QGIS Python Console with the planet project open, read the
plan banner it prints **before** it starts working, and let it write
`assets/qgis/export/<planet>_chunks/heights.pack` plus `manifest.json`. Point the planet's
`PlanetData.chunk_heightmaps_dir` at that folder; `PlanetTerrain.initialize()` reads the
manifest and applies radius, tiling and elevation range on its own.

---

## POI pipeline (`export_poi.py` → inspector button)

Turns the `poi` point layer into `Area3D` zones inside the planet scene, so the
lon/lat → X/Y/Z conversion described in §4.3 no longer has to be done by hand.

1. **Draw the POIs** in QGIS on the `poi` layer (see "Place Points of Interest"
   below), filling in `name`, `poi_type`, `population`, `radius` (metres) and
   `description`. Leave `elevation` empty unless you want to *override* the
   terrain height at that spot.
2. **Export** from the QGIS Python Console:
   ```python
   exec(open('…/tools/planettech/qgis/export_poi.py').read())
   ```
   Output: `<EXPORT_DIR>/<planet>_poi.json` — a flat list of
   `{id, name, poi_type, population, radius, description, lon, lat, elevation}`.
   `planet_name` / `planet_radius_m` are read from the QGIS project variables,
   like `export_elevation.py`.
3. **Import in Godot**: open the planet scene, select the **`PlanetTerrain`**
   node, and click **"Import POI from JSON"** in the inspector. Leave
   `poi_json_path` empty to use `assets/qgis/export/<planet_name>_poi.json`.

The button (re)builds a `POIs` child holding one `Area3D` per POI:

- named after the POI, positioned at its lon/lat **on the terrain surface**
  (height sampled from the heightmap, +Y along the surface normal — the same
  `compute_surface_transform()` the "Snap to planet surface" tool uses);
- with a `SphereShape3D` of the POI's `radius`;
- carrying the QGIS attributes as node metadata (`poi_id`, `poi_type`,
  `population`, `description`, `lon`, `lat`).

The nodes are owned by the edited scene, so **save the scene** to keep them.
Re-running the button replaces the whole `POIs` subtree rather than appending,
so a re-export from QGIS is always safe to re-import.

> The generated areas use `collision_layer`/`collision_mask` = 0 by default —
> they are inert markers. Set `poi_collision_layer` / `poi_collision_mask` on
> `PlanetTerrain` **before** importing if gameplay code needs to detect them.

---

## Roads pipeline (`export_roads.py`)

Unlike the POI pipeline, **the Godot side needs no button**: roads are generated
inside `PlanetChunk.generate_mesh()`, so they appear as soon as the data file
exists — in the running game *and* in the editor preview, which calls the same
mesh generator.

1. **Draw the roads** in QGIS on the `highway` / `road` / `path` / `trail` / `railway` layers
   (see "Draw Roads" below). The layer *is* the road type and drives everything;
   `width` (total, metres) is pre-filled and optional. A legacy single `roads`
   layer with a `road_type` field is still exported when present.
2. **Export** from the QGIS Python Console:
   ```python
   exec(open('…/tools/planettech/qgis/export_roads.py').read())
   ```
   Two outputs, in this order:
   - `<planet>_chunks/parts/roads.dsmpart` — **what the game reads**, then merged
     into `<planet>_chunks/terrainmodifier.pack` by the automatic relink;
   - `<EXPORT_DIR>/<planet>_roads_buffered.json` — the legacy GeoJSON, still read
     by `BiomeQuery` during the transition.
3. **Nothing to wire in Godot**: chunks read `terrainmodifier.pack` from
   `chunk_heightmaps_dir` directly. Reopen the scene to regenerate the preview.

---

## Regions pipeline (`export_biomes.py`)

A **region** is a polygon drawn on one of the Region layers (`outcrop/plateau`,
`regolith/sand`, `maritime river/ocean`…). Its biome identity is a property of
the layer (`biome_type`, `biome_index`, `color_hex`, `ds_priority` — set by
`setup_planet_project.py`); what varies per polygon are its fields: `rock_type`
and `clarity` (see `layers/rocks.py`), `name`, `density`…

1. **Draw** the regions in QGIS.
2. **Export** from the QGIS Python Console:
   ```python
   exec(open('…/tools/planettech/qgis/export_biomes.py').read())
   ```
   Outputs `<planet>_chunks/parts/biomes.dsmpart`, relinks
   `terrainmodifier.pack`, and rewrites `assets/_universe/_shared/materials/rocks.json`.
3. **Godot** reads the pack directly (nothing to click): `PlanetChunk` asks the
   tile for its zones, finds the first zone containing each vertex, and colours
   it — with the rock's tints when the zone has a `rock_type` (see below), else
   the `BiomeDefinition` colour, else the layer's `color_hex`.

### How a region is stored

Godot never sees the whole polygon. For every level n1 … export_nside (n256 on
tarsis_8, 13.9 km tiles) and every HEALPix tile the polygon touches
(`modifier_geom.tiles_for_polygon`), the exporter writes ONE POPULATE record:

- **full** — the tile's lon/lat box lies entirely inside the polygon
  (`modifier_geom.bbox_inside_ring`): 12 bytes + props, no geometry, and every
  vertex of the tile matches;
- **partial** — the polygon clipped to the tile (`clip_polygon_to_bbox`) and
  simplified to a quarter of the level's vertex pitch (`simplify_ring`): the
  runtime does a point-in-polygon test on that small ring.

So a chunk only ever loads the zones of its own tile: thousands of regions on a
planet cost nothing to a chunk that sees two of them. Only the OUTER ring of a
polygon is exported — an enclave is another region drawn on top.

### Overlap rule

Records of a tile are written by descending **category priority**
(`Category.priority` in `layers/`: liquids 300, regolith 200, outcrop 100,
everything else 0) and, at equal priority, smallest area first. Godot keeps its
"first matching zone wins" rule, so the file order IS the priority: loose cover
beats bedrock, a small zone beats the large one it sits in.

### Props

`rock_type`, `clarity`, `name` and the layer's `color_hex` as string ids, plus
every other non-null field — numbers as f32 (`density`, `canopy_height`,
`depth`…), anything else as a string id. The runtime readers today:
`rock_type` (colour), `color_hex` (fallback colour), `density` (vegetation),
`depth` (cliffs).

### Rocks: catalogue + tint

The rock itself is **not** in the pack. `rocks.json` (from `layers/rocks.py`)
holds, per slug, the colour range `[light, dark]`, the night range of chameleon
rocks, the impurities in ppm per element, the sub-minerals and the `surface`
flag. `RockCatalogue` (Godot) loads it once; `RockCatalogue.tint(dir, radius,
slug)` blends the light tint toward the dark one with a deterministic two-octave
value noise of the position (`SurfaceNoise`, the same hash the corundum cracks
use) — a pure function of the vertex direction, so every client and the server
bake the same shades, and a zone shows every hue between its two tints instead
of one flat colour.

An **outcrop** biome (`outcrop-plateau`, `outcrop-volcanic`) also carries a
`terrain_material_override` — the hex-tiled corundum rock of SandboxCapital,
saved as `mat_mineral_corundum_pure/corundum_outcrop_surface.tres` with
`vertex_color_strength = 1`: `PlanetChunk` emits the quads of such zones as a
separate mesh surface with that material, and the rock tint in COLOR multiplies
the (white) texture. Region edges are hard between the two surfaces for now.

The part manifest's `fingerprint` is echoed into the pack manifest and into the
chunk cache key, so re-exporting the regions re-bakes the vertex colours.

### Relief

A biome may add a light undulation to the ground of its zones —
`BiomeDefinition.relief_min_m / relief_max_m / relief_wavelength_m` (the outcrop
plateau uses −0.5 m … +1 m over ~60 m, the volcanic outcrop −1 … +2 m over 40 m).
`BiomeRelief.offset()` is a pure function of the vertex direction (value noise +
a finer octave at a third of the wavelength), applied identically by the mesh,
its normal probes and the collision shape, and dropped — never faded — on any
grid whose vertex pitch reaches half the wavelength, so the two geometries never
disagree. Keep wavelengths at tens of metres: the finest grid is ~13.5 m.

Roads flatten it: the relief is 0 within `half-width + 1.5 vertex pitches` of
any road / railway centreline (≥ 2 m) and ramps back to full at `+ 3 pitches`
(≥ 10 m) — the relief lives on vertices and the surface between them is
interpolated, so every vertex of a triangle touching the road must be flat for
the ribbon or the bed (both on the raw heightmap) not to be pierced. A planet with such a
biome switches the server to the fine collision grid, like cracks and profiled
lines (`PlanetData.collision_detail_nside()`).

## Terrain-modifier pack (`terrainmodifier.pack`)

The per-chunk, per-LOD archive of everything that modifies terrain — roads,
craters, linear features (rivers, lava, dry beds, canyons), radial features
(caves, fumaroles, volcanoes) and biome populate zones. POIs are **not** in it:
they are an editor-only import baked into the `.tscn`.

```
assets/qgis/export/<planet>_chunks/
    heights.pack            DSHP — elevation tiles (unchanged)
    manifest.json
    terrainmodifier.pack    DSMP — DERIVED, written by link_modifiers.py
    parts/
        strings.json        global, APPEND-ONLY string table
        roads.dsmpart       written by export_roads.py
        …                   one part per feature family
```

**Each exporter owns one part.** Re-running `export_roads.py` rewrites
`roads.dsmpart` and relinks the pack from every part present, so it replaces the
roads and leaves the other families untouched. Because the string table only ever
grows, ids stay valid forever and the linker copies record blocks byte for byte —
two links over unchanged parts produce a byte-identical pack.

```python
# chain several exporters, link once
NO_LINK = True   # set at the top of each exporter
exec(open('…/tools/planettech/qgis/export_roads.py').read())
import link_modifiers; link_modifiers.link('tarsis_4')

# a checkout that has the pack but no parts/
link_modifiers.explode('tarsis_4')
```

### Why roads are stored per chunk

A road used to be stored **once, globally**. `PlanetChunk.generate_mesh()` then
walked its entire centerline in *every* chunk whose bounding box touched it — a
13 km road with 1177 points, rebuilt in dozens of chunks. Worse, neighbouring
chunks at different LODs sample terrain height at different pyramid levels
(`PlanetData.sample_nside_for()`), so the duplicate ribbons landed at **different
altitudes**: in game you saw two roads, the upper one floating about 2 m up.

In the pack a road is **partitioned**: at every level, each point belongs to
exactly one HEALPix tile, pieces are split on the tile boundary, and the two
pieces meeting there share a bit-identical vertex. A chunk draws its own stretch
and nothing else, so the duplication is impossible by construction rather than
avoided by a runtime test. On tarsis_4 the longest road goes from 1177 points
rebuilt per chunk to ~7 points per chunk at n8192.

Roads must be baked down to `PlanetData.max_quadtree_depth` (13 on tarsis_4,
n8192). A shallower bake would make deeper chunks share an ancestor tile — the
duplication again — so `link_modifiers.link()` refuses to build such a pack and
`PlanetData` warns at load time.

Craters, radial features and biome zones stop at `export_nside` instead: they are
point and polygon *queries*, never emitted geometry, so a shared ancestor tile is
harmless — and baking a biome polygon covering a quarter of a planet down to
n8192 would need hundreds of millions of tiles.

### Format

`DSMP v1`, spec'd in
[`export/planet/dsmp.py`](export/planet/dsmp.py) and mirrored by the reader
[`scenes/planet/modifier_pack.gd`](../../scenes/planet/modifier_pack.gd).
Coordinates are `i32` in units of 1e-7° (~1.1 cm) — `float32` loses 0.85 m at
100° of longitude, a quarter of a road's width. Unlike `heights.pack`, tiles are
sparse and variable-size, so each level carries a sorted index that the reader
binary-searches **in place** on the raw bytes (a level can hold millions of
entries; materialising them as a `Dictionary` would cost ~100 bytes of Variant
each and stall the main thread at `open()`).

Every polyline point stores its distance from the start of the **unclipped**
feature. Recomputing it from a clipped piece would restart at 0 in every tile, so
a river would snap back to its start width at each chunk seam and a road's
asphalt texture would jump at every chunk boundary.

Tests: [`test/unit/test_modifier_pack.gd`](../../test/unit/test_modifier_pack.gd),
[`test/unit/test_modifier_pack_py.py`](../../test/unit/test_modifier_pack_py.py)
(`python3` alone, no QGIS) and
[`test/unit/test_road_no_double_render.gd`](../../test/unit/test_road_no_double_render.gd).
The two encoders are pinned to each other by a shared SHA-256 of one canonical
tile, so neither can drift silently.

### Bridges over the procedural chasms

On a corundum planet the "canyons" are **not** data: they are the crack network
generated at runtime by `ArideDesertCorundumPlateauTerrain.crack_offset()` — on
tarsis_4, gorges 250 m wide and 180 m deep every 4 km. Nothing to intersect at
QGIS time, so bridge sites cannot be baked into the pack.

The road ribbon samples the RAW heightmap and never applies the crack offset, so
it already flies over every gorge at rim altitude. The server collision *does*
carve them. That mismatch is the bug: you drive along a ribbon suspended over
nothing and fall through it. Measured on tarsis_4, **8 to 14 % of every road is
over a 180 m void — 35 crossings across the 5 roads**, spans from 188 m to 731 m
(the widest ones are oblique crossings of the same 250 m gorge).

Because `crack_offset()` is a pure function of a direction plus the `PlanetData`
parameters, the crossings are found by walking the roads and evaluating the
field ([`RoadBridge`](../../scenes/planet/road/road_bridge.gd)) — and the client
and the server, walking the same roads, find bit-identical spans with nothing
replicated between them. A coarse walk at a quarter of the gorge width cannot
miss one, and each rim is then bisected to 1 m; a naive fixed 5 m walk cost 1.8 s
of frozen main thread, this costs ~190 ms and is done once at planet init.

A span can be longer than a chunk, so each is assigned to the single chunk
containing its **midpoint**, which builds the whole structure — the same
ownership trick that stops the road ribbon being drawn twice.

Bridge scenes declare their own geometry, rather than relying on a pivot
convention:

| metadata | meaning |
|---|---|
| `deck_height` | height of the driving surface above the scene origin, in metres |
| `span_length` | length of one bay along +X |
| `road_width` | usable deck width (optional) |
| `repeatable` | true when the bay may be tiled to cover any span |

Declared values are checked at load time; a mis-authored pivot is only visible
in game. `wind_valley.tscn` is the reason: its origin sits at the base of its
piers, about 97 m below the deck. It stays a hand-placed landmark — a repeated
landmark is no longer a landmark — while
[`bridge_module.tscn`](../../scenes/_universe/structures/industrial/bridge_module.tscn)
is the placeholder module the spawner tiles. Replace its primitives with the
finished art and keep the metadata block.

### Grade-limited lines: railways, and roads with `max_slope_degrees`

Two kinds of line leave the terrain-hugging ribbon and are built on a
**longitudinal profile** — `scenes/planet/road/grade_*.gd`, one code path:

- a `railway` (KIND_ROAD record, `road_type = "railway"`; its `tracks` count
  travels in the record's `lanes` slot and the decoder hands it back as `tracks`);
- a `highway` or `road` whose QGIS `max_slope_degrees` is set. The exporter
  writes it in the record's layout-2 tail (`u8 flags | u8 max_slope_deg | u16 pad`
  after `point_count`) and counts such roads in the road part manifest
  (`"profiled_roads"`); the road part manifest also says `"record_layout": 2`,
  and a pack without that key (older exports) is still decoded with the
  24-byte header — nothing to re-export.

What differs between the two is asked in one place, `GradeSettings`
(`is_profiled`, `max_grade_of`, `climbs_at_max_grade_of`, `half_width_of`,
`bed_material_of`, `span_kind_of`); `RailwaySettings` keeps what is physically
rail (track module, bed width per track, ballast, the 4 % "stay level" policy),
`RoadTerrain` the road answers (width from the record, asphalt, climb at
`tan(max_slope_degrees)`).

- **Profile** (`GradeProfile`, computed once per line at planet load, from the
  same `heights.pack` sampler on the client and the server): the line starts at
  the terrain's altitude and is laid in 200 m windows; when the terrain at the
  end of a window is further than the max grade allows from the current
  altitude, a railway stays level through that window
  (`RailwaySettings.CLIMB_AT_MAX_GRADE`) while a graded road climbs at exactly
  its max grade toward the terrain. Every 5 m the terrain is classified against
  the line: **cutting** (terrain above, less than 10 m), **tunnel** (10 m or
  more), **viaduct** (terrain more than 2 m below), or ground.
- **Bed** (`GradeBed`): a ribbon at the profile's altitude — ballast for a
  railway, asphalt for a road — with skirts down to the ground, built into the
  chunk mesh *and* the chunk collision shape.
- **Rails** (railway only, `RailwayTrack`): `railroad_01.glb` (half a track:
  half a sleeper + one rail, 1.12 m) instanced every 1.12 m, two mirrored halves
  per track, tracks 1 m apart at the sleeper ends, in one `MultiMeshInstance3D`
  per 64 m of line. Collision is a box per track per straight run, not the model.
- **Cuttings** carve the finest grid (vertices lowered to a floor + 45° walls)
  in both the mesh and the fine collision; the cells they cross are re-meshed
  8× finer (`GradeRefine`).
- **Tunnels** (`GradeTunnel`): an arched concrete tube with a headwall at each
  mouth; the terrain triangles crossing the bore are dropped in the refined patch.
- **Viaducts**: `BridgeDeck` decks pinned to the profile, at most 400 m each;
  span kind `"railway"` or `"profiled_road"` (asphalt deck), never confused with
  the crack-based road bridges.
- A planet with any profiled line switches the server to fine collision
  (`PlanetData.collision_detail_nside()` → the finest quadtree level), like
  the corundum planets.

Widths: `tracks` decides for a railway (see the table below), which has no
`width` field; a graded road keeps its `width`. Bench:
`godot --headless --path . res://test/parity/railway_probe.tscn` writes the
profile summary and a mesh/collision parity check to `user://railway_probe.txt`.

### Why buffered polygons (legacy GeoJSON)

Godot loads that file through `BiomeQuery`, whose parser **only accepts `Polygon`
geometry** — a raw LineString export is silently ignored. So each road is
buffered into a polygon and the original line is kept in `properties.centerline`:

- the **polygon** is only a coarse detection volume (deliberately
  `DETECTION_MULTIPLIER` = 3× wider than the road) so a chunk crossed by a narrow
  trail is never missed by the bounding-box test;
- the **visible ribbon** is extruded from the centerline at the real half-width,
  with flow-aligned UVs, and sits `SURFACE_OFFSET` = 5 cm above the ground.

The pack needs neither: its tiles are partitioned, not bbox-tested. This file
disappears once `PlanetData.roads_geojson` is retired.

Roads do **not** displace the terrain, and have no collision of their own — they
ride on the terrain collision — except a `highway` / `road` with
`max_slope_degrees`, which is built like a railway (see above).

### Width

`RoadTerrain.get_half_width_m()` and the exporter apply the same rule: the
per-feature `width` from QGIS wins when it is set, otherwise the `road_type`
default applies.

| road_type | default total width | material |
|---|---|---|
| `highway` | 12 m | asphalt (fixed) |
| `road` | 6 m | asphalt (fixed) |
| `path` | 2 m | biome-adaptive (grass / dirt / sand / snow) |
| `trail` | 1 m | biome-adaptive |
| `railway` | `tracks`·2.44 m + (`tracks`−1)·1 m + 1 m shoulders (3.44 m for one track, 6.88 m for two); 5 m when `tracks` is unset | ballast bed + rail modules (`railroad_01.glb`) |

A railway is the one type with no `width` field at all: its layer only has
`name`, `tracks` and `speed_limit`, and the ballast bed is derived from
`tracks` in both `RailwaySettings.railway_half_width_m()` and
`export/planet/roads.py`.

`HALF_WIDTH_M` in [`scenes/planet/road/road_terrain.gd`](../../scenes/planet/road/road_terrain.gd)
and `HALF_WIDTH_M` in [`export/planet/roads.py`](export/planet/roads.py) **must
stay in sync**. The Python side now lives in that one module (imported by
`export_roads.py`) rather than being duplicated, so there are exactly two copies
to keep aligned instead of three.

> **Known limitation:** widths are computed in degree space with no `cos(lat)`
> correction, so a road narrows in longitude away from the equator — about 9 % at
> 25° of latitude, 50 % at 60°. Fixing it means touching the export buffer, the
> ribbon builder and `BiomeQuery.get_cross_section_t()` together, otherwise the
> rendering and the vegetation suppression desynchronise.

---

## How to Use — Quick Start

### Prerequisites

- **QGIS 3.44** installed ([download](https://qgis.org/en/site/forusers/alldownloads.html))
- **Godot 4.5** with double-precision build (your current project setup)
- Your planet scene already has a `Planet` node with `PlanetTerrain`, `PlanetSettings`, etc.

---

### Step 1: Create a New Planet Project in QGIS

1. Open **QGIS** and make sure the PostgreSQL connection **`DyingStar`** exists
   (**Layer → Data Source Manager → PostgreSQL**).
2. Open the **Python Console** (**Plugins → Python Console**, or **Ctrl+Alt+P**)
3. Optionally edit the defaults at the top of `setup_planet_project.py`
   (`PLANET_NAME`, `PLANET_RADIUS_M`, `WORK_DIR`, `EXISTING_FEATURES`)
4. Run the script:
   ```python
   exec(open('/datas/developpement/sources/DyingStar-game/DyingStar/tools/planettech/qgis/setup_planet_project.py').read())
   ```
5. Two dialogs:
   - **planet name + radius** — the name is the PostGIS schema and the `.qgz` name
   - **layer picker** — a checkable tree `Region / POI / Lines → category → layer`.
     Untick what this planet will never use. Under a layer that declares a value
     list (rock types…), tick the values that exist on this planet: they become
     that field's dropdown. On a re-run, layers already in the database are
     pre-ticked. Unticking removes the layer from the project and drops its
     table **only if it is empty** — drawn data is never deleted.
6. The layer tree is organised by **geometry**, then by category:
   - **Region** — polygon layers: `world border`, `region`, then one sub-group per
     biome category (`forest/temperate forest`, `aride desert/sandy desert`…)
   - **POI** — point layers: `poi` (cities, stations, spawn points), `spatial/crater`,
     `volcanic geothermal/ice geyser`…
   - **Lines** — line layers: `contours`, `roads/highway|road|path|trail|railway`,
     `maritime river/river`, `icy/ice crevasse`…

Each layer is a PostGIS table named after its slug (`sandy_desert`, `river`,
`highway`) in the schema `<planet_name>`. Re-running the script on an existing
planet loads the tables untouched and re-applies widgets/styles from the
definitions. The project is saved to `<WORK_DIR>/<planet_name>/<planet_name>.qgz`.

#### Layer definitions (`layers/`)

```
layers/
  __init__.py      registry: discovers categories, creates the tree (setup_all)
  model.py         Category / BiomeCategory / Layer / Field / Range / Color / ValueMap
  core.py          PostGIS: schema, tables, last_updated trigger, widgets, symbols
  dialog.py        the two Qt dialogs
  rocks.py         ROCK_TYPES shared value list + rock_field()
  base.py          world border, contours, region
  poi.py           poi
  roads.py         highway / road / path / trail / railway (one layer each)
  biomes/
    forest.py, icy.py, maritime_river.py, …   one module per biome category
```

A biome is three lines in its category module:

```python
CATEGORY.biome(
    11, 'temperate_forest', '#2d5a1e',
    'Forest formation composed of deciduous trees or mixed stands…',
    planet_type='terrestrial',
    fields=[
        Field('density', 'double', 'Vegetation density 0.0-1.0', widget=Range(0.0, 1.0, 0.01)),
        Field('canopy_height', 'integer', 'Canopy height in metres', widget=Range(0, 200, 1)),
    ],
)
```

`biome_type` becomes `<category>-<slug>` (`forest-temperate_forest`), the table
`<slug>`, the QGIS name `<slug with spaces>`. `geom='LineString'` / `'Point'`
moves the layer to **Lines** / **POI**; `terrain_modifier=True` flags biomes that
alter the heightmap. `fields=[rock_field()]` adds the per-planet rock dropdown.
Every biome layer carries `biome_type`, `biome_index`, `color_hex`,
`terrain_modifier`, `planet_type`, `ds_category`, `ds_layer` as QGIS custom
properties — that is what the export scripts read.

To add a category: create `layers/biomes/<name>.py` with
`CATEGORY = BiomeCategory('<name>')`. Nothing to register. Unique tables,
`biome_type` and `biome_index` are enforced at load time. `BiomeCategory(...,
priority=N)` sets the overlap priority of its Region layers (written on the
layer as `ds_priority`, applied by `export_biomes.py` — see "Regions pipeline").

---

### Step 2: Design Your Planet

Now use the standard QGIS editing tools to draw your planet's features. The coordinate system is **EPSG:4326** (longitude/latitude in degrees), which maps directly onto the planet sphere:

- **X = Longitude**: −180° (left) to +180° (right)
- **Y = Latitude**: −90° (south pole) to +90° (north pole)

#### Draw Elevation Contours
1. Select the **Lines → contours** layer in the Layers panel
2. Click the **pencil icon** (Toggle Editing) in the toolbar
3. Click **Add Line Feature** (the line drawing tool)
4. Draw a contour line on the map — each click adds a vertex, double-click to finish
5. In the popup dialog, enter the `elevation` value in meters (e.g., `500`)
6. Repeat for more contour lines at different elevations
7. Click the **floppy disk icon** to save edits

#### Draw Biome Zones
1. Select the biome's layer (e.g. **Region → forest → temperate forest**) → Toggle Editing
2. Click **Add Polygon Feature** (or line / point for biomes living under **Lines** / **POI**)
3. Draw the zone — double-click to close the polygon
4. In the popup, fill in the biome-specific fields (`name`, `density`, `canopy_height`,
   `radius`, `width_start`…). The biome type and index are properties of the layer,
   not of the feature — nothing to type.
5. Save edits

#### Draw Roads
1. Select the road type's layer (**Lines → roads → highway / road / path / trail / railway**) → Toggle Editing
2. Click **Add Line Feature** and draw the road
3. `width`, `lanes`, `surface`, `speed_limit`… are pre-filled for that road type; override per feature if needed.
   A railway only asks for `tracks` (and `speed_limit`) — its bed width follows the track count.
   On a `highway` / `road`, `max_slope_degrees` is empty by default (the road hugs the
   terrain); set it and Godot builds the road on a grade-limited profile with cuttings,
   tunnels and viaducts
4. **Tip**: enable snapping (**Project → Snapping Options** or press **S**) so roads connect at intersections
5. Save edits

#### Place Points of Interest
1. Select the **POI → poi** layer → Toggle Editing
2. Click **Add Point Feature** and click where you want to place a city, station, or spawn point
3. Fill in: `name`, `poi_type` (city/station/landmark/spawn_point), `population`,
   `radius` (influence radius in metres) and `description`
4. Save edits, then see the POI pipeline section above to get them into Godot

#### Draw Water Bodies
1. Select **Region → maritime river → ocean** (or `lake`, `delta`…; rivers are
   lines under **Lines → maritime river → river**) → Toggle Editing
2. Click **Add Polygon Feature** and outline the area
3. Fill in the optional fields (`name`, `water_color`, `salinity`…)
4. Save edits

> **Tip**: Save your QGIS project often (**Ctrl+S**). You can reopen it anytime from `assets/qgis/<planet>.qgz`.

---

### Step 3: Export from QGIS

> **This section describes the retired `export_planet.py` pipeline** (now
> `export_planet_old.py`): global heightmap, 16-bit per-chunk PNGs, cube-sphere projection,
> `.planetpack` recipes. None of it is read at runtime any more, and the command below will not
> resolve.
>
> For **elevation**, use `export_elevation.py` — see
> [Elevation — from contours to a pack](https://developper.dyingstar-game.com/docs/planetTech/elevation_export).
> The sections above cover POI, roads and the modifier pack. Biomes and water still go through
> the retired path and have not been re-documented.

When your planet design is ready (or whenever you want to test in Godot):

1. In the QGIS Python Console, **edit the configuration** at the top of `export_planet.py`:
   - `PLANET_NAME` — must match what you used in Step 1
   - `PLANET_RADIUS` — your planet radius in meters (e.g., `5000`)
   - `EXPORT_DIR` — path to `assets/qgis/export/` in your project
   - `ELEV_MIN` / `ELEV_MAX` — elevation range for heightmap normalization
2. Run the export:
   ```python
   exec(open('/datas/developpement/sources/StarDeception/StarDeception/tools/planettech/qgis/export_planet.py').read())
   ```
3. The script performs **6 steps** automatically:
   1. **Exports all vector layers** as GeoJSON files to `assets/qgis/export/`
   2. **Generates a global heightmap** (TIF) from contour lines using TIN/IDW interpolation
   3. **Generates chunked heightmaps** — splits the global heightmap into per-chunk
      16-bit PNGs using the same cube-sphere projection as Godot's terrain system.
      The max quadtree depth is computed automatically from the planet radius.
   4. **Generates a biome raster map** from biome polygons
   5. **Generates a far-LOD color map** (small RGB image for ultra-distance rendering)
   6. **Creates a planet metadata JSON** with file references, chunk manifest, and LOD configuration

Output files in `assets/qgis/export/`:
```
tarsis_4_elevation.geojson    ← contour lines
tarsis_4_biomes.geojson       ← biome polygons
tarsis_4_roads.geojson        ← road network
tarsis_4_poi.geojson          ← points of interest
tarsis_4_water.geojson        ← water bodies
tarsis_4_heightmap.tif        ← global rasterized elevation (source for chunks)
tarsis_4_chunks/              ← per-chunk 16-bit heightmap PNGs
│   chunk_manifest.json       ← chunk metadata (face, depth, UV bounds)
│   face_0/ ... face_5/       ← 256×256 PNG per chunk (e.g. f0_d3_0_0.png)
tarsis_4_biomemap.tif         ← rasterized biome indices
tarsis_4_colormap.png         ← far-LOD color texture
tarsis_4_planet.json          ← metadata + LOD config + chunk manifest ref
```

---

### Step 4: Import into Godot

Once the QGIS export script has been run, the planet textures and metadata sit in
`assets/qgis/export/`.  This step turns them into a playable planet inside Godot.

#### 4.1 — Planet system overview

The planet system lives in `scenes/planet/` and is built around four scripts:

| File | Role |
|---|---|
| `planet_data.gd` | `PlanetData` **Resource** — radius, textures, LOD distances, coordinate helpers |
| `planet_body.gd` | `Planet` **Node3D** — root node, client / server orchestration, atmosphere hook |
| `planet_terrain.gd` | `PlanetTerrain` — quadtree manager, creates / destroys chunks each frame |
| `planet_chunk.gd` | `PlanetChunk` — static mesh & collision-shape generators |

The generic template `base_planet.tscn` provides the default node hierarchy and is
preloaded by `NetworkOrchestrator`.  Each specific planet (e.g. `tarsis_4.tscn`) is
a standalone scene that references these scripts with its own `PlanetData` sub-resource.

#### 4.2 — Node hierarchy

```
Planet (Node3D)  ← planet_body.gd, holds PlanetData resource
├── PlanetTerrain (Node3D)  ← planet_terrain.gd
│   ├── Chunks (Node3D)  ← dynamic: MeshInstance3D children
│   └── PlayerSpawnPointsList (Node3D)
│       └── PlayerSpawnPoint01 (Marker3D)
├── FarLODSphere (MeshInstance3D)  ← simple sphere + colormap texture
└── Atmosphere (instance)  ← extremely_fast_atmosphere (optional)
```

#### 4.3 — Creating a new planet scene

1. **Create the scene file** in `scenes/systems/<system>/<planet>.tscn`.
2. **Add ext_resources** for the three scripts (`planet_body.gd`, `planet_terrain.gd`,
   `planet_data.gd`) and for each exported texture (`heightmap.png`, `biomemap.png`,
   `colormap.png`).
3. **Define a PlanetData sub-resource** and set its properties from the
   `<planet>_planet.json` metadata produced by QGIS:

   | Property | Source |
   |---|---|
   | `planet_name` | filename stem, e.g. `"tarsis_4"` |
   | `radius` | `planet.json → radius` |
   | `max_height` | highest contour value (e.g. `1000.0`) |
   | `atmosphere_height` | ≈ 2-3 % of radius |
   | `lod0_distance` … `lod4_distance` | `planet.json → lod_config` |
   | `chunk_heightmaps_dir` | Relative path to chunks dir, e.g. `assets/qgis/export/tarsis_4_chunks` |
   | `chunk_export_depth` | From `chunk_manifest.json → export_depth` (e.g. `3`) |
   | `heightmap` | (Optional fallback) ExtResource to global heightmap PNG |
   | `biomemap` / `colormap` | ExtResource refs to the exported PNGs |
   | `chunk_resolution` | `32` (vertices per chunk edge at LOD 0) |
   | `max_quadtree_depth` | `planet.json → max_quadtree_depth` (auto-computed from radius) |

4. **Build the node tree** as shown in §4.2.  The root `Node3D` gets `planet_body.gd`;
   `PlanetTerrain` gets `planet_terrain.gd`.
5. **Add spawn points** as `Marker3D` children of `PlayerSpawnPointsList`.  Convert
   longitude / latitude from the POI GeoJSON to 3D:

   ```
   x = radius × cos(lat_rad) × cos(lon_rad)
   y = radius × sin(lat_rad)
   z = radius × cos(lat_rad) × sin(lon_rad)
   ```

6. **(Optional) Add an atmosphere** — instance
   `addons/extremely_fast_atmosphere/atmosphere/atmosphere.tscn` as a child and set
   `planet_radius` and `atmosphere_height`.  The sun reference is resolved automatically
   at runtime by `planet_body.gd`.

#### 4.4 — LOD system (cube-sphere quadtree)

The terrain uses a **cube-sphere projection** with 6 root faces, each recursively
subdivided into a quadtree based on camera (client) or closest-player (server) distance.

| LOD | Distance | Chunks | Rendering |
|---|---|---|---|
| 0 | < `lod0_distance` | 32 × 32 verts | Full detail terrain mesh |
| 1 | < `lod1_distance` | 16 × 16 verts | Medium detail mesh |
| 2 | < `lod2_distance` | 8 × 8 verts | Low detail mesh |
| 3 | < `lod3_distance` | 8 × 8 verts | Coarse patches + far-LOD sphere |
| 4 | < `lod4_distance` | — | Far-LOD sphere only (colormap) |

The quadtree updates every **0.25 s**.  Chunks behind the planet (dot < −0.3) are
culled on the client.

#### 4.5 — Client / server split

| Concern               | Client      | Server  |
|-----------------------|-------------|---------|
| Terrain meshes        | ✔ MeshInstance3D per chunk | ✘ |
| Collision shapes      | ✘           | ✔ ConcavePolygonShape3D (LOD 0-1 only) |
| Base sphere collision | ✘           | ✔ SphereShape3D (all distances) |
| Atmosphere            | ✔           | ✘       |
| Far-LOD sphere        | ✔ (LOD ≥ 3) | ✘       |

The role is detected at runtime via `GameOrchestrator.is_server()`.

#### 4.6 — Example: Tarsis 4

`scenes/systems/tarsis/tarsis_4.tscn` is a complete reference planet:

- Radius **2 118 666 m**, max terrain height **1 000 m**
- Textures from `assets/qgis/export/tarsis_4_*.png`
- LOD distances: 5 000 / 50 000 / 200 000 / 2 000 000 / 500 000 000 m
- One spawn point (mine village) at lon −83.7°, lat 11.5°
- Atmosphere with 50 km shell height

Use this scene as a template when adding new planets.

---

## Useful QGIS Shortcuts

| Key | Action |
|---|---|
| **Ctrl+Alt+P** | Open Python Console |
| **E** | Toggle layer editing |
| **Ctrl+Z** | Undo |
| **Ctrl+S** | Save project |
| **Ctrl+Shift+S** | Save all layers |
| **S** | Toggle snapping |
| **V** | Select/Move tool |
| **Scroll wheel** | Zoom in/out |
| **Middle mouse** | Pan the map |