class_name ForcedDustWall
extends Node3D
## A dust wall called in by an admin (the Alt+T wheel's "admin_spawn_dust_wall") instead of drawn from the
## relief's hashes: a networked prop parented to its planet, like a WeatherSystem. It holds no physics and
## draws nothing by itself: it is DATA that ClimateWeather.walls_at adds to the walls it draws
## (WeatherRelief.forced_wall), so the drawing (WeatherPhenomena), the wind and the dust, the light, the
## sound and the village alarm follow it on every machine exactly as they follow a wall of the hashes.
##
## Its front runs from (origin_lon, origin_lat) at born_at, along (east, north) at speed_m_s, on the shared
## clock (Globals.sim_time()): nothing moves on the wire. The server deletes it at dies_at, once it has run
## past the village it was called on (a delete for Horizon too: it is a test object, not world data).

const GROUP := &"forced_dust_walls"
## Horizon's type of the prop (items_def/dust_wall_def.json, and ds_genericprops/props/ in horizonserver).
const TYPE_NAME := "dust_wall"
const SCENE := "res://scenes/_universe/environment/weather/forced_dust_wall.tscn"
## How long before it reaches the village centre the wall is placed upwind, seconds of simulation time:
## short, so the test does not wait, and long enough to see it coming and hear the warning first (3 soundings,
## the wall 2.7 km out when called). At 90 s it stood within a kilometre when it appeared (2026-11-28).
const LEAD_S := 180.0
## The called-in wall: its speed (m/s), the length of its front and its height (m), within the drawn walls'
## ranges (WeatherRelief.WALL_SPEED_M_S, WALL_LENGTH_M, WALL_HEIGHT_M).
const SPEED_M_S := 15.0
const LENGTH_M := 20000.0
const HEIGHT_M := 1500.0
## Kept after its dusty air, tail included (passed_after_s), has left the village centre, seconds: its fade
## (WeatherRelief.FORCED_FADE_S) happens past the village, not over it.
const PASSED_MARGIN_S := 60.0
## Under this wind (m/s) there is no upwind to place the wall in: it comes from where the admin looks.
const CALM_M_S := 1.0

var origin_lon: float = 0.0
var origin_lat: float = 0.0
var east: float = 0.0
var north: float = 1.0
var speed_m_s: float = SPEED_M_S
var length_m: float = LENGTH_M
var height_m: float = HEIGHT_M
var born_at: float = 0.0
var dies_at: float = 0.0
## Stable id derived from the uuid: the key the presenters keep the wall under.
var id: int = 0


func _ready() -> void:
	add_to_group(GROUP)
	var net := PropSync.of(self)
	if net != null:
		id = hash(net.uuid)
	# Only the server deletes it; a client keeps it until Horizon says it is gone (its fade has run by then).
	set_process(GameOrchestrator.is_server())
	print("[Weather] dust wall called in under %s, %.0f m/s, ends at %.0f" % [
			get_parent().name if get_parent() != null else "?", speed_m_s, dies_at])


## Called by PropSync with the (possibly partial) channel data Horizon sent. Every number through float():
## Horizon's JSON hands a whole number back as an int.
func apply_prop_data(data: Dictionary) -> void:
	for key: String in ["origin_lon", "origin_lat", "east", "north", "speed_m_s", "length_m", "height_m", "born_at",
			"dies_at"]:
		if data.has(key):
			set(key, float(data[key]))


## SERVER: gone once it has run past (the server's clock is the one the end was set on). Also ends one a
## restart found persisted long after its end.
func _process(_delta: float) -> void:
	if dies_at > 0.0 and ClimateWeather.now() >= dies_at:
		set_process(false)
		queue_free()


## What WeatherRelief.forced_wall reads.
func data() -> Dictionary:
	return {"id": id, "origin_lon": origin_lon, "origin_lat": origin_lat, "east": east, "north": north,
		"speed_m_s": speed_m_s, "length_m": length_m, "height_m": height_m, "born_at": born_at, "dies_at": dies_at}


## The prop's network data (NetworkOrchestrator.spawn_prop_authoritative) for a wall whose front reaches
## [param target] (lon, lat in degrees) LEAD_S after [param t], running along [param way] (east, north; any
## length): placed upwind of it by SPEED_M_S × LEAD_S, plus how far its front as drawn leads the line through
## its middle there (upwind_m). Parented to the planet [param planet_uuid] at [param at_local] (the target in
## the planet's frame: where its GORC zone is centred).
static func spawn_data(planet_uuid: String, uuid: String, at_local: Vector3, target: Vector2, way: Vector2, t: float,
		radius_m: float) -> Dictionary:
	var dir := way.normalized() if way.length() > 1e-6 else Vector2(0.0, 1.0)
	var origin := WeatherRelief.moved(target, -dir * upwind_m(), radius_m)
	return {
		"type": TYPE_NAME,
		"uuid": uuid,
		"scenename": SCENE.trim_prefix("res://"),
		"parent_id": planet_uuid,
		"position": {"x": at_local.x, "y": at_local.y, "z": at_local.z},
		"rotation": {"x": 0.0, "y": 0.0, "z": 0.0},
		"origin_lon": origin.x,
		"origin_lat": origin.y,
		"east": dir.x,
		"north": dir.y,
		"speed_m_s": SPEED_M_S,
		"length_m": LENGTH_M,
		"height_m": HEIGHT_M,
		"born_at": t,
		"dies_at": t + passed_after_s() + PASSED_MARGIN_S,
	}


## How long after it is called in the end of the wall's dusty tail (WeatherRelief.wall_reach_m) has left the
## village centre, seconds: the front reaches it after LEAD_S, the tail trails WALL_TAIL_DEPTHS depths behind
## and grows with the depth as it runs (WeatherRelief.forced_wall: WALL_DEPTH_M + WALL_SPREAD x speed x run).
## The front past the centre by speed x (run - LEAD_S) meets the tail's reach at that run. Ended at the front's
## passing plus the wall's own depth, it vanished with its tail still over the village (2026-11-28).
## The village is the middle of the front, where the drawn front leads the line through it by _lead_share() of
## the wall's depth, a share that grows with the depth as it runs.
static func passed_after_s() -> float:
	var trail := WeatherRelief.WALL_TAIL_DEPTHS
	var grows := _lead_share() * WeatherRelief.WALL_SPREAD
	return (LEAD_S * (1.0 + grows) + trail * WeatherRelief.WALL_DEPTH_M / SPEED_M_S) \
			/ (1.0 + grows - trail * WeatherRelief.WALL_SPREAD)


## How far upwind of the village the middle of the wall's front is placed, m: its run over LEAD_S, plus how far
## its drawn front (WeatherRelief.front_lead_m) leads that middle once it has run so long, so that the front the
## player sees, and whose dust, sound and alarm follow it, reaches the village after LEAD_S.
static func upwind_m() -> float:
	var depth := WeatherRelief.WALL_DEPTH_M + WeatherRelief.WALL_SPREAD * SPEED_M_S * LEAD_S
	return SPEED_M_S * LEAD_S + _lead_share() * depth


## The drawn front's lead at the middle of a wall, as a share of its depth (no bow there).
static func _lead_share() -> float:
	return WeatherRelief.front_lead_m(0.0, 1.0, 1.0)
