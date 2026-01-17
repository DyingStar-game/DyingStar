# QGIS Tools for StarDeception — Quick Start

This folder contains the QGIS ↔ Godot pipeline scripts for designing and importing planet data.

> **Full documentation**: see [`docs/QGIS_PLANET_WORKFLOW.md`](../../docs/QGIS_PLANET_WORKFLOW.md) for the complete step-by-step QGIS guide (layer creation, styling, coordinate system explanation, etc.).

---

## Files Overview

| File | Runs In | Purpose |
|---|---|---|
| `setup_planet_project.py` | QGIS Python Console | Creates a new QGIS project with all the standard layers (contours, biomes, roads, POI, water) pre-configured |
| `export_planet.py` | QGIS Python Console | Exports all layers to GeoJSON + generates heightmap, biome raster, and far-LOD color map |
| `qgis_planet_importer.gd` | Godot Editor | Reads the exported files and generates terrain textures, biome maps, and POI markers for your Planet node |

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
3. Fill in: `name`, `poi_type` (city/station/landmark/spawn_point), `population`, `radius`
4. Save edits

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