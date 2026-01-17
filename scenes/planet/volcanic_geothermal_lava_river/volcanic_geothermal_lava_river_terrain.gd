@tool
class_name VolcanicGeothermalLavaRiverTerrain
## Terrain module for the **volcanic_geothermal-lava_river** linear biome.
##
## A flowing lava channel carved into the terrain, filled with a
## hot_flowing_lava material surface that sits at the original terrain
## level — just like water in a river.  The terrain below is depressed
## with a steep U-shape (1 − t⁴), and the lava surface mesh is built
## separately at the pre-depression height so it visually fills the
## channel like a liquid.
##
## Category: volcanic.  Layer group: linear.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "volcanic_geothermal-lava_river"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 86
## Category tag for grouping.
const CATEGORY := "volcanic"

## Half-width of the lava channel in metres.
## Narrower than a canyon (120 m) but wider than a dry riverbed (40 m).
const HALF_WIDTH_M := 60.0

## Default depth of the channel in metres (if not overridden per-feature).
## Shallow enough so the lava floor texture is clearly visible.
const DEFAULT_DEPTH_M := 25.0

## The lava surface sits slightly below the original terrain level so
## it doesn't z-fight with the surrounding ground.  Positive = inset.
const SURFACE_OFFSET := 0.15

## Texture tile size in metres.  The lava texture repeats at this scale
## along the flow-aligned UV axes.  40 m gives ~1.5 repeats across the
## full 120 m channel width — large enough to look smooth and continuous.
const TILE_M := 40.0


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition + zone describe a
## lava river (linear feature with centerline).
static func matches_zone(bd: BiomeDefinition, zone: Dictionary) -> bool:
	if bd == null or bd.biome_type != BIOME_TYPE:
		return false
	var cl: PackedVector2Array = zone.get("centerline", PackedVector2Array())
	return cl.size() >= 2


## Convert the fixed half-width from metres to degrees and cache it
## in the zone dictionary so BiomeQuery.get_cross_section_t() can use it.
static func prepare_zone(zone: Dictionary, planet_radius: float) -> void:
	if not zone.get("_hw_converted", false):
		var m_per_deg := planet_radius * PI / 180.0
		zone["half_width_deg"] = HALF_WIDTH_M / m_per_deg
		zone["_hw_converted"] = true
