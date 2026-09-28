class_name StationSite
extends Resource
## One station of the universe: where it orbits, what it is called, and the uuid it lives under on
## the network. The single source of truth for everything that needs to know a station exists
## without it being loaded — the teleporter's destination list, the star map, the seed generator
## (tools/stations/station_seed.gd) — and for the station itself, which looks its site up by uuid.
##
## Stored as scenes/systems/<system>/stations/<name>.tres; list them with StationSites.

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


## The uuid the station is seeded under. Derived, never stored: the seed, the server and every client
## compute the same one from the id.
func uuid() -> String:
	return PropSpawn.stable_uuid("station:" + id)


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
