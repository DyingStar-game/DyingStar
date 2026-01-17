@tool
class_name MeadowSteppeMeadowTerrain
## Terrain module for the **meadow_steppe-meadow** biome.
##
## A temperate biome dominated by a continuous herbaceous layer and soils
## rich in organic matter, favored by regular but insufficient rainfall for
## the development of a dense forest cover.
## Category: terrestrial.  Layer group: individual (polygon).
##
## Unlike point-biomes (fumarole, volcanic_geothermal-active_volcano), meadow is an
## **area biome** — it covers large terrain regions rather than a single
## landmark.  Grass blade geometry is scattered per-chunk via
## [MeadowSteppeMeadowSpawner] at close LODs; at far LODs the terrain vertex
## colour alone provides the green hue.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "meadow_steppe-meadow"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 8
## Category tag for grouping.
const CATEGORY := "terrestrial"

## Maximum LOD level at which grass blade geometry is spawned.
## At higher LODs the terrain vertex colour alone provides the look.
const GRASS_MAX_LOD := 2

## Per-LOD tuft budget and blade count.
## Each tuft is a clump of N OBJ grass-stalk blades merged into one
## ArrayMesh, randomly rotated and offset within a small radius.
## The OBJ stalk has ~9 tris, so:
##
## LOD 0 (closest):  8 blades × 9 tris = 72 tris/tuft, 500 000 tufts → 36.0 M tris.
## LOD 1 (medium):   4 blades × 9 tris = 36 tris/tuft, 200 000 tufts →  7.2 M tris.
## LOD 2 (far):      2 blades × 9 tris = 18 tris/tuft,  80 000 tufts →  1.4 M tris.
const GRASS_LOD_BUDGET := [500000, 200000, 80000]
const GRASS_LOD_BLADES := [8, 4, 2]

## Maximum grass tuft instances per terrain chunk (LOD 0 value, kept
## for any code that doesn't pass a chunk_lod).
const GRASS_MAX_PER_CHUNK := 500000

## Physical grass blade density at [code]density = 1.0[/code].
## Real-world temperate grass ≈ 6–14 blades/cm²; 10 is a good middle.
## Multiplied by the zone's authored [code]density[/code] to allow sparser
## patches (e.g. density 0.3 = 3 blades/cm²).
const BLADES_PER_CM2 := 10.0
## Derived: tufts per m² at full density.
## = BLADES_PER_CM2 * 10 000 / blades_per_tuft_lod0
## Pre-computed here so it's available without importing the spawner.
const TUFTS_PER_M2_FULL := BLADES_PER_CM2 * 10000.0 / 8.0  # ~12 500

## Minimum spacing in metres between grass tuft centres.
## Each tuft is a ~70 cm diameter clump of blades (TUFT_RADIUS = 0.35 m).
## 0.12 m grid resolution ensures maximum candidate density; the budget
## cap does the actual thinning.
const GRASS_MIN_SPACING_M := 0.12

# ── Palette (inspired by David Hoskins' "Rolling Hills") ──────────

const COL_GRASS_BASE := Color(0.05, 0.28, 0.02)
const COL_GRASS_MID  := Color(0.18, 0.38, 0.06)
const COL_GRASS_TIP  := Color(0.38, 0.52, 0.20)
const COL_DRY_GRASS  := Color(0.44, 0.42, 0.18)
const COL_WILDFLOWER := Color(0.60, 0.28, 0.52)
const COL_EARTH      := Color(0.30, 0.22, 0.12)


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is meadow.
static func is_meadow_biome(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE

## Alias kept for consistency with all other biome terrain modules.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return is_meadow_biome(bd)
