class_name StarMapZones
extends RefCounted
## What the ground of a body is MADE of, tile by tile, from the terrain's own modifier pack.
##
## The chart painted every body in one flat colour, taken from the star chart's own palette. The ground
## is not one colour: the level design lays down zones of rock — corundum in three shades, emery — and
## they are what makes one stretch of a planet look unlike the next. The pack records them, keyed by the
## same HEALPix tiles everything else here is keyed by, so this is a lookup and nothing more.
##
## The zone a point falls in is decided here by its outline, not by the game's [code]first_zone_at[/code]
## — which resolves a great deal more than a colour and is, on this export, silent past n256.

const PACK_PATH: String = "%s/%s_chunks/terrainmodifier.pack"

var body_key: String = ""
## The rock this body falls back on where no zone names one. Read from the planet's scene by the chart.
var default_rock: String = ""
## Metres per degree on this body, which is what the pack needs to turn a crest's width into an extent
## on the ground. Set by the chart alongside the body.
var m_per_deg: float = 0.0

var _pack: ModifierPack = null
var _tried: bool = false
var _known: Dictionary = {}


## What one tile is made of, and what stands on it: a fallback rock, the patches of other rock laid over
## it with the outline of each, and the massifs and crests the level design put there.
##
## The OUTLINES matter. One rock per tile was tried first and the biomes came out as rectangles — the
## boundary between blue corundum and white followed the edges of the mesh's own tiles instead of the
## shape the level design drew, which reads as a bug in the chart rather than as ground. The pack has
## the polygons: two to four per tile, five to eleven points each.
##
## Answered once per tile and remembered: a tile does not change, and the chart asks about the same few
## hundred of them four times a second.
func tile_of(nside: int, ipix: int) -> Dictionary:
	var id: int = StarMapGround.tile_id(nside, ipix)
	if _known.has(id):
		return _known[id]
	var patches: Array[Dictionary] = []
	var mountains: Array = []
	var ridges: Array = []
	if _open() and _pack.has_tile(nside, ipix):
		# One read and one decode for both questions. The pack prepares the massifs and crests as
		# MountainRelief's own Zone and Ridge objects, so there is nothing to convert here.
		var tile: Dictionary = _pack.decode_tile(_pack.read_tile(nside, ipix), m_per_deg,
				ModifierPack.MASK_POPULATE | ModifierPack.MASK_MOUNTAIN | ModifierPack.MASK_RIDGE)
		for entry: Variant in (tile["populate_zones"] as Array):
			var zone: Dictionary = entry
			var rock: String = str(zone.get("rock_type", ""))
			if rock == "" or not RockCatalogue.has(rock):
				continue
			var poly: PackedVector2Array = zone.get("polygon", PackedVector2Array())
			if poly.size() < 3:
				continue
			patches.append({"rock": rock, "polygon": poly})
		mountains = tile["mountain_zones"]
		ridges = tile["ridge_lines"]
	var made: Dictionary = {"fallback": default_rock, "patches": patches,
			"mountains": mountains, "ridges": ridges}
	_known[id] = made
	return made


func close() -> void:
	if _pack != null:
		_pack.close()
		_pack = null
	_known.clear()
	_tried = false
	body_key = ""
	default_rock = ""


# ---------------------------------------------------------------------------

func _open() -> bool:
	if _pack != null:
		return true
	if _tried or body_key == "":
		return false
	_tried = true
	var made := ModifierPack.new()
	if not made.open(PACK_PATH % [StarMapRelief.EXPORT_ROOT, body_key]):
		return false
	_pack = made
	return true
