class_name TeleportDestination
extends RefCounted

## One place a teleporter can send you, and the ONE definition of how that place crosses the network.
##
## A destination is always a body plus a longitude/latitude plus a height — never a cartesian offset.
## That is deliberate: the seven hard-coded pads this replaces stored raw Vector3 offsets, one of
## which (the Xarok pad) was silently 5 662 km wrong because it had been copied from a planet with a
## nine-times-larger radius. lon/lat cannot carry that mistake: the height is resolved against the
## destination's OWN terrain, at the moment of use.
##
## [method to_payload] / [method from_payload] are the wire contract. Keeping both halves in this one
## file is the point — the UI, the cabin and the server all speak through them, so a renamed field
## cannot break a reader that nobody remembered to update.

## Where the height is measured FROM.
enum Height {
	GROUND,  ## metres above the terrain at that lon/lat — resolved server-side, see TeleportGround
	SEA,  ## metres above the planet's reference radius, whatever the ground does there
}

## Where the entry came from. Presentation only — the server treats them all alike.
enum Kind {
	POI,  ## a point of interest exported from QGIS
	DERIVED,  ## computed for any body (poles, equator, low orbit)
	MANUAL,  ## longitude/latitude typed in by hand
	RETURN,  ## where this trip started
}

var label: String = ""
## PlanetData.planet_name — "tarsis_3". The one stable key across scenes, POI files and tiles.
var planet_name: String = ""
var lon: float = 0.0
var lat: float = 0.0
var height: float = 0.0
var height_mode: Height = Height.GROUND
var kind: Kind = Kind.MANUAL
## Second line in the list: a POI's type and population, or what a derived point is.
var detail: String = ""


func _init(p_label: String = "", p_planet: String = "", p_lon: float = 0.0, p_lat: float = 0.0,
		p_height: float = 0.0, p_mode: Height = Height.GROUND, p_kind: Kind = Kind.MANUAL,
		p_detail: String = "") -> void:
	label = p_label
	planet_name = p_planet
	lon = p_lon
	lat = p_lat
	height = p_height
	height_mode = p_mode
	kind = p_kind
	detail = p_detail


## Human form for a log line or a confirmation: "SandBox — lon -8.291 lat 0.127, 2 m above ground".
func describe() -> String:
	var frame: String = "above ground" if height_mode == Height.GROUND else "above sea level"
	return "%s @ %s lon %.4f lat %.4f, %.1f m %s" % [label, planet_name, lon, lat, height, frame]


## Wire form. Plain strings for the mode so a captured log reads without a decoder ring.
func to_payload() -> Dictionary:
	return {
		"planet": planet_name,
		"lon": lon,
		"lat": lat,
		"height": height,
		"height_mode": "ground" if height_mode == Height.GROUND else "sea",
		"label": label,
	}


## Rebuild from the wire. Anything missing falls back to a value that is safe rather than clever:
## an unknown mode means GROUND, which resolves against real terrain instead of trusting a number.
static func from_payload(payload: Dictionary) -> TeleportDestination:
	var mode: Height = Height.SEA if str(payload.get("height_mode", "")) == "sea" else Height.GROUND
	return TeleportDestination.new(
			str(payload.get("label", "")),
			str(payload.get("planet", "")),
			float(payload.get("lon", 0.0)),
			float(payload.get("lat", 0.0)),
			float(payload.get("height", 0.0)),
			mode)


## True when this describes a real place. lon/lat are checked because a typed field can hold anything,
## and a latitude of 400 would silently normalise to somewhere nobody asked for.
func is_valid() -> bool:
	return planet_name != "" \
		and lon >= -180.0 and lon <= 180.0 \
		and lat >= -90.0 and lat <= 90.0 \
		and is_finite(height)
