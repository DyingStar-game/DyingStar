@tool
class_name ForestTemperateForestTerrain
## Terrain module for the **forest-temperate_forest** biome.
##
## Forest formation composed of deciduous trees or mixed stands.
## It features a thick layer of decomposing litter.
## Category: terrestrial.  Layer group: individual (polygon).
## Includes default vegetation density and tree-type constants
## used by PlanetVegetation when no per-feature override exists.
##
## At close LODs, [ForestTemperateForestSpawner] scatters lowpoly tree
## instances via [MultiMesh].  At far LODs the terrain vertex colour
## alone provides the dark-green hue.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "forest-temperate_forest"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 11
## Category tag for grouping.
const CATEGORY := "terrestrial"
## Default vegetation density when the QGIS feature has no override.
const DEFAULT_VEGETATION_DENSITY := 0.8
## Default tree type for VegetationRule matching.
const DEFAULT_TREE_TYPE := "deciduous"
## Forest leaf-litter ground texture tile size in metres.
const TILE_M := 3.0
## Path to the leaves ground material used as a terrain overlay.
const MATERIAL_PATH := "res://assets/materials/planet/forest_ground_leaves.tres"

# ── Tree scatter constants ─────────────────────────────────────────

## Per-LOD tree instance budget per chunk.
## Indexed by LOD tier (0 = closest).  If the GLB contains more LOD
## levels than entries here, the last value is reused for any extra tiers.
const TREE_LOD_BUDGET: Array[int] = [2000, 800, 200]

## Minimum spacing in metres between tree centres.
## Real temperate forests have ~3–8 m spacing; 4 m gives a dense look
## while keeping instance count manageable.
const TREE_MIN_SPACING_M := 4.0

## Trees per m² at full density (density = 1.0).
## Temperate deciduous forest ≈ 400–1200 stems/ha = 0.04–0.12 per m².
## 0.06 is a good middle value.
const TREES_PER_M2_FULL := 0.06

## Scale range for random tree size variation.
const TREE_SCALE_MIN := 0.6
const TREE_SCALE_MAX := 1.4

## Returns the tree instance budget for [param lod_tier], clamping to the
## last entry when the tier exceeds the table size.
static func get_tree_budget(lod_tier: int) -> int:
	var idx := clampi(lod_tier, 0, TREE_LOD_BUDGET.size() - 1)
	return TREE_LOD_BUDGET[idx]


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a temperate forest.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
