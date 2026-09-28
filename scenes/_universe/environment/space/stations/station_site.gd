class_name StationSite
extends Resource
## One station of the universe: where it orbits, what it is called, and the uuid it lives under on
## the network. The single source of truth for everything that needs to know a station exists
## without it being loaded — the teleporter's destination list, the star map, the seed generator
## (tools/stations/station_seed.gd) — and for the station itself, which looks its site up by uuid.
##
## Stored as scenes/systems/<system>/stations/<name>.tres; list them with StationSites.

## The networked scene every station is built from unless its site names another.
const DEFAULT_SCENE := "res://scenes/_universe/environment/space/stations/orbital_station.tscn"
const DEFAULT_EVA_RADIUS_M := 50000.0

enum AltitudeMode {
	## altitude_m above the body's reference radius.
	FIXED,
	## The orbit whose period is the body's day: it stays above one point of the ground. altitude_m
	## is ignored; the radius comes from the body's mass and day.
	SYNCHRONOUS,
}

## Stable identity, "<body>/<name>" (e.g. "tarsis_3/palaka_pital"). The uuid is derived from it, so
## renaming it makes a DIFFERENT station for the database.
@export var id: String = ""
## The body it orbits: its scene key ("tarsis_3").
@export var body_key: String = ""
## Its proper name; the kind of station is added around it (see display_name).
@export var proper_name: String = ""
@export var altitude_mode: AltitudeMode = AltitudeMode.FIXED
## Metres above the body's reference radius (FIXED only).
@export var altitude_m: float = 400000.0
## Against the body's equator, degrees.
@export var inclination_deg: float = 0.0
## Longitude of the ascending node about the body's spin axis, degrees.
@export var ascending_node_deg: float = 0.0
## Where on its orbit the station is at t = 0 (mean anomaly), degrees.
@export var phase_deg: float = 0.0
## The networked scene the station is built from: orbital_station.tscn, or a scene INHERITED from it with
## another model under `Model` (and its own `Arrival` marker). It becomes the seed's `scenename`
## (tools/stations/station_seed.gd). A path, not a PackedScene: the star map and the teleporter read the
## sites, and must not load a station's whole model to do it.
@export_file("*.tscn") var scene: String = DEFAULT_SCENE
## How far from the station a weightless body still rides in its frame, in metres (OrbitalStation.holds).
##
## A body let go beside a station is on an orbit of its own, next to the station's: the station's frame
## is the right one to describe it in — it is the co-moving frame of orbital mechanics (LVLH) — PROVIDED
## the body drifts the way that frame says it does (OrbitalStation.relative_acceleration:
## Clohessy-Wiltshire). Those equations are linearised: ~1 % off at 70 km from a 400 km orbit, and the
## error grows with the distance over the orbit's radius. Past this radius the body falls back to its
## planet's frame.
@export var eva_radius_m: float = DEFAULT_EVA_RADIUS_M


## The uuid the station is seeded under. Derived, never stored: the seed, the server and every client
## compute the same one from the id.
func uuid() -> String:
	return PropSpawn.stable_uuid("station:" + id)


## The scene as the network names it (the seed's `scenename`): its path without "res://".
func scenename() -> String:
	return scene.trim_prefix("res://")


## "Palaka-Pital Orbital Station" / "Station orbitale Palaka-Pital".
func display_name() -> String:
	return tr("%%STATION_NAME_ORBITAL") % proper_name


## Its orbit, from the body's saved properties (SystemScenes.body_properties, or body_props_of on a
## live Planet).
func orbit(body_props: Dictionary) -> StationOrbit:
	var mass_kg: float = float(body_props.get("orbit_mass_earths", 0.0)) * Planet.MASS_EARTH
	var radius: float = SystemScenes.radius_of(body_props) + altitude_m
	if altitude_mode == AltitudeMode.SYNCHRONOUS:
		var day_s: float = float(body_props.get("rotation_period_hours", 0.0)) * 3600.0
		radius = StationOrbit.synchronous_radius(KeplerOrbit.G * mass_kg, day_s)
	return StationOrbit.new(radius, deg_to_rad(inclination_deg), deg_to_rad(ascending_node_deg),
			deg_to_rad(phase_deg), mass_kg, deg_to_rad(float(body_props.get("axial_tilt_deg", 0.0))))


## Altitude above the reference radius, whatever the mode, in metres.
func altitude_above(body_props: Dictionary) -> float:
	return orbit(body_props).radius_m - SystemScenes.radius_of(body_props)


## The properties orbit() reads, taken from a LIVE body instead of its scene file.
static func body_props_of(body: Node) -> Dictionary:
	var out: Dictionary = {}
	for key: String in ["map_radius_km", "orbit_mass_earths", "rotation_period_hours", "axial_tilt_deg"]:
		out[key] = body.get(key)
	return out
