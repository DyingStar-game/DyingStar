@tool
class_name CaveTerrain
## Self-contained constants and helpers for cave-entrance terrain depressions.
##
## The cave biome creates a physical hole in the terrain mesh by collapsing
## vertices inside a small radius to a single deep point, surrounded by a
## smooth taper funnel.  All constants are local to this module so that
## changing cave parameters cannot break river or canyon biomes.

# ── Constants ──────────────────────────────────────────────────────

## Radius of the smooth taper zone around the cave entrance (metres).
const ENTRANCE_RADIUS_M := 50.0
## Radius of the actual hole in the terrain mesh (metres).
## Vertices inside this radius are collapsed to a degenerate point,
## creating zero-area triangles that act as a true opening.
const HOLE_RADIUS_M := 22.0
## Depth below the surface for collapsed vertices (metres).
const ENTRANCE_DEPTH_M := 60.0
## Biome types that receive cave entrance depressions.
const BIOME_TYPES: PackedStringArray = ["rocky_landform-cave"]


# ── Detection helpers ──────────────────────────────────────────────

## Returns true if the biome definition is a cave type.
static func is_cave_biome(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type in BIOME_TYPES


## Check whether a zone should produce a cave entrance.
## Used during chunk overlap detection.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return is_cave_biome(bd)


# ── Coordinate helpers ─────────────────────────────────────────────

## Convert a lon/lat Vector2 (degrees) to a unit direction vector.
static func lonlat_to_dir(lonlat: Vector2) -> Vector3:
	var lon_rad := deg_to_rad(lonlat.x)
	var lat_rad := deg_to_rad(lonlat.y)
	return Vector3(
		cos(lat_rad) * cos(lon_rad),
		sin(lat_rad),
		cos(lat_rad) * sin(lon_rad)
	).normalized()
