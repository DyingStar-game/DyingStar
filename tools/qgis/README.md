# QGIS Tools for StarDeception — Quick Start

This folder contains the QGIS ↔ Godot pipeline scripts for designing and importing planet data.

> **Full documentation**: see [`docs/QGIS_PLANET_WORKFLOW.md`](../../docs/QGIS_PLANET_WORKFLOW.md) for the complete step-by-step QGIS guide (layer creation, styling, coordinate system explanation, etc.).

---

## Files Overview

| File | Runs In | Purpose |
|---|---|---|
| `setup_planet_project.py` | QGIS Python Console | Creates a new QGIS project with all the standard layers (contours, biomes, roads, POI, water) pre-configured |
| `export_elevation.py` | QGIS Python Console | **Elevation-only**: one raw float32 (`.r32`) heightmap tile per HEALPix chunk, for the standard mesh terrain (no recipes/voxels). See below. |
| `export_poi.py` | QGIS Python Console | **POI-only**: flattens the `poi` point layer to `<planet>_poi.json`, read back by the `PlanetTerrain` inspector button. See below. |
| `export_roads.py` | QGIS Python Console | **Roads-only**: writes `parts/roads.dsmpart` (per chunk, per LOD) and relinks `terrainmodifier.pack`; also still writes the legacy `<planet>_roads_buffered.json`. See below. |
| `link_modifiers.py` | QGIS console or `python3` | Reassembles `terrainmodifier.pack` from every `parts/*.dsmpart`. Called automatically by each exporter; `--explode` does the reverse. See below. |
| `export/planet/dsmp.py` | library | Authoritative DSMP/DSMQ format spec + encoder. No QGIS import, unit-testable with plain `python3`. |
| `export/planet/modifier_geom.py` | library | Tile assignment, clipping, decimation. Holds the road **partition** that makes double-rendering impossible. |
| `export/planet/dsmp_strings.py` | library | The append-only `parts/strings.json` intern table. |
| `export/planet/roads.py` | library | Road widths (the single Python mirror of `RoadTerrain.HALF_WIDTH_M`) and the ROAD part builder. |
| `export_planet_old.py` | QGIS Python Console | **Retired** full pipeline (biome GeoJSON, spatial tiles, `.planetpack` recipes). Kept for reference; its outputs are no longer read at runtime. |

---

## Elevation-only mesh pipeline (`export_elevation.py`)

A focused exporter that feeds the existing mesh terrain (`scenes/planet/`) directly
from QGIS contour lines — no recipe `.planetpack`, no voxels.

1. **Edit config** at the top of `export_elevation.py` (or set the QGIS project
   variables `planet_name` / `planet_radius_m`):
   - `PLANET_RADIUS = 6_356_000` (metres)
   - `NSIDE = 64` → 12·64² = **49152 chunks** (`chunk_export_depth = 6`)
   - `TILE_RES = 25` (samples per chunk edge)
   - `EXPORT_DIR` → your `assets/qgis/.export` path
2. **Run** in the QGIS Python Console:
   ```python
   exec(open('…/tools/qgis/export_elevation.py').read())
   ```
   Output: `<EXPORT_DIR>/<planet>_chunks/face_{0..11}/f{ipix}.r32` + `manifest.json`.
3. **Wire the planet in Godot**: on the planet's `PlanetData` set
   `chunk_heightmaps_dir = "assets/qgis/.export/<planet>_chunks"` (relative to
   `res://`). `PlanetTerrain.initialize()` reads `manifest.json` and auto-applies
   `radius`, `export_nside`, `chunk_heightmap_res`, `height_offset`, `max_height`.
   No other fields need setting for elevation.

**Format note:** tiles are raw float32 (`FORMAT_RF`), normalized `[0,1]` over
`[elev_min, elev_max]`, loaded losslessly via `Image.create_from_data`. (16-bit PNG
is avoided because Godot downsamples it to 8-bit on import → terracing.) Decode is
`elev = pixel.r * max_height + height_offset`.

> When `chunk_heightmaps_dir` is empty, the terrain falls back to the recipe
> pipeline (`export_planet.py`) as before — the two are mutually exclusive per planet.

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
   exec(open('…/tools/qgis/export_poi.py').read())
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

1. **Draw the roads** in QGIS on the `roads` layer (see "Draw Roads" below).
   `road_type` drives everything; `width` (total, metres) is optional.
2. **Export** from the QGIS Python Console:
   ```python
   exec(open('…/tools/qgis/export_roads.py').read())
   ```
   Two outputs, in this order:
   - `<planet>_chunks/parts/roads.dsmpart` — **what the game reads**, then merged
     into `<planet>_chunks/terrainmodifier.pack` by the automatic relink;
   - `<EXPORT_DIR>/<planet>_roads_buffered.json` — the legacy GeoJSON, still read
     by `BiomeQuery` during the transition.
3. **Nothing to wire in Godot**: chunks read `terrainmodifier.pack` from
   `chunk_heightmaps_dir` directly. Reopen the scene to regenerate the preview.

---

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
exec(open('…/tools/qgis/export_roads.py').read())
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
ride on the terrain collision.

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

1. Open **QGIS**
2. Open the **Python Console**: menu **Plugins → Python Console** (or press **Ctrl+Alt+P**)
3. In the console, **edit the configuration** at the top of `setup_planet_project.py`:
   - `PLANET_NAME` — your planet identifier (e.g., `"tarsis_4"`)
   - `WORK_DIR` — path to `assets/qgis/` in your project
   - `EXISTING_FEATURES` — path to your existing `planet_features.geojson` (if any)
4. Run the script:
   ```python
   exec(open('/datas/developpement/sources/StarDeception/StarDeception/tools/qgis/setup_planet_project.py').read())
   ```
5. QGIS now has **5 empty layers** ready for editing, plus your existing features loaded:
   - `<planet>_contours` — LineString layer for elevation contour lines
   - `<planet>_biomes` — Polygon layer for biome zones (forest, desert, ocean…)
   - `<planet>_roads` — LineString layer for roads and paths
   - `<planet>_poi` — Point layer for cities, stations, spawn points
   - `<planet>_water` — Polygon layer for oceans and lakes

The project is auto-saved to `assets/qgis/<planet_name>.qgz`.

---

### Step 2: Design Your Planet

Now use the standard QGIS editing tools to draw your planet's features. The coordinate system is **EPSG:4326** (longitude/latitude in degrees), which maps directly onto the planet sphere:

- **X = Longitude**: −180° (left) to +180° (right)
- **Y = Latitude**: −90° (south pole) to +90° (north pole)

#### Draw Elevation Contours
1. Select the `<planet>_contours` layer in the Layers panel
2. Click the **pencil icon** (Toggle Editing) in the toolbar
3. Click **Add Line Feature** (the line drawing tool)
4. Draw a contour line on the map — each click adds a vertex, double-click to finish
5. In the popup dialog, enter the `elevation` value in meters (e.g., `500`)
6. Repeat for more contour lines at different elevations
7. Click the **floppy disk icon** to save edits

#### Draw Biome Zones
1. Select the `<planet>_biomes` layer → Toggle Editing
2. Click **Add Polygon Feature**
3. Draw the outline of a biome zone (e.g., a forest area) — double-click to close the polygon
4. In the popup, fill in:
   - `biome_type`: e.g., `forest`, `desert`, `ocean`, `meadow_steppe-meadow`, `tundra`, `snow`
   - `biome_index`: the index into your biome texture array (0–7)
   - `density`: vegetation density from 0.0 to 1.0
   - `color_hex`: dominant color for ultra-far LOD (e.g., `#2d5a1e` for forest)
5. Save edits

#### Draw Roads
1. Select the `<planet>_roads` layer → Toggle Editing
2. Click **Add Line Feature** and draw road paths
3. Fill in: `name`, `road_type` (highway/road/path/trail), `width` in meters, `lanes`, `surface`
4. **Tip**: enable snapping (**Project → Snapping Options** or press **S**) so roads connect at intersections
5. Save edits

#### Place Points of Interest
1. Select the `<planet>_poi` layer → Toggle Editing
2. Click **Add Point Feature** and click where you want to place a city, station, or spawn point
3. Fill in: `name`, `poi_type` (city/station/landmark/spawn_point), `population`,
   `radius` (influence radius in metres) and `description`
4. Save edits, then see the POI pipeline section above to get them into Godot

#### Draw Water Bodies
1. Select the `<planet>_water` layer → Toggle Editing
2. Click **Add Polygon Feature** and outline ocean or lake areas
3. Fill in: `name`, `water_type` (ocean/lake/river), `depth`
4. Save edits

> **Tip**: Save your QGIS project often (**Ctrl+S**). You can reopen it anytime from `assets/qgis/<planet>.qgz`.

---

### Step 3: Export from QGIS

When your planet design is ready (or whenever you want to test in Godot):

1. In the QGIS Python Console, **edit the configuration** at the top of `export_planet.py`:
   - `PLANET_NAME` — must match what you used in Step 1
   - `PLANET_RADIUS` — your planet radius in meters (e.g., `5000`)
   - `EXPORT_DIR` — path to `assets/qgis/export/` in your project
   - `ELEV_MIN` / `ELEV_MAX` — elevation range for heightmap normalization
2. Run the export:
   ```python
   exec(open('/datas/developpement/sources/StarDeception/StarDeception/tools/qgis/export_planet.py').read())
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