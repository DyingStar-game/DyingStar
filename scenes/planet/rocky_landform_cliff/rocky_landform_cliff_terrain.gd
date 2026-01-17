@tool
class_name RockyLandformCliffTerrain
## Terrain module for the **rocky_landform-cliff** biome.
##
## Rocky escarpment with a near-vertical slope resulting from tectonic
## processes or erosion.
## Category: terrestrial.  Layer group: individual (polygon).
##
## The cliff polygon drawn in QGIS defines the lower plateau.  Vertices
## inside the polygon are pushed downward, with a steep transition band
## near the polygon boundary that creates the cliff face.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "rocky_landform-cliff"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 24
## Category tag for grouping.
const CATEGORY := "terrestrial"

## Total height drop from the cliff edge to the lower plateau (metres).
const DROP_M := 50.0
## Width of the steep transition band at the polygon boundary (metres).
## A 15 m band with 50 m drop gives an ~73° slope — near-vertical.
const BAND_M := 15.0

## Path to the ORMMaterial3D used on vertical cliff faces.
const MATERIAL_PATH := "res://assets/materials/planet/cliff.tres"
## Slope threshold for cliff face detection (dot of normal with planet up).
## Triangles with slope below this value are considered vertical cliff.
const SLOPE_THRESHOLD := 0.5
## Texture tiling: cliff material repeats every N metres.
const TILE_M := 6.0


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a rocky_landform-cliff.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE


# ── Displacement ───────────────────────────────────────────────────

## Compute the cliff height offset for a vertex inside a cliff polygon.
## [param dist_to_edge_m] — distance from the vertex to the nearest
##   polygon edge, in metres (0 at boundary, positive going inward).
## [param drop] — optional override for the total drop (metres).
## Returns a **negative** offset to subtract from the terrain height.
static func height_offset(dist_to_edge_m: float, drop: float = DROP_M) -> float:
	if dist_to_edge_m >= BAND_M:
		return drop
	# Quadratic ramp: steep near the edge, flattening at the base.
	var t := dist_to_edge_m / BAND_M
	return drop * t * t
