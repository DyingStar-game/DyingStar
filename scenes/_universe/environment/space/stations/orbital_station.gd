class_name OrbitalStation
extends NetStaticBody
## An orbital station: a networked structure (type "station") that players live in — the city of
## space — and that ORBITS its body for real.
##
## It moves the way a moon does. On the SERVER nothing celestial moves: the station's body keeps the pose
## it was created with, and the players inside hold positions local to it, the same whether it moves or
## not. On each CLIENT it is placed every frame from the time, on the orbit its StationSite describes
## (StationOrbit), and its children — the players inside — are carried by the scene graph. Every
## client computes the same point from the same clock.
##
## Placed every FRAME, not at the planets' 3 Hz: at 7 km/s a third of a second is 2.3 km, a jump the
## people inside would see the whole planet make.
##
## Horizon keeps the station where it was seeded. Telling it where the station really is was tried, and
## measured: each update moved the station 7.7 km, and Horizon moves what hangs under it one object at a
## time, checking zones at every step — so every second a player aboard left their own zone and came
## back (38 times in 35 s), and would have seen every other passenger vanish and reappear. What is aboard
## is placed relative to the station, which is all a client needs; the price is that a body drifting out
## of the station's frame (its site's eva_radius_m) is compared with the seed pose, and its client loses
## the station.

## Where travellers arrive (the teleporter): a Marker3D child, local to the station.
const ARRIVAL_NODE := "Arrival"

var _site: StationSite = null
## A uuid no StationSite answers to: looked up once, not re-read from disk every frame (see site()).
var _site_missing_for: String = ""
var _orbit: StationOrbit = null


func _ready() -> void:
	if GameOrchestrator.is_server() or Engine.is_editor_hint():
		set_process(false)
		return
	# On its orbit from the very first frame, not the next one. What arrives off the network is the
	# server's fixed pose, and a traveller can be put aboard in the same frame the station is created
	# (the teleporter): measured, 4 321 km from the true station for that one frame.
	_place_on_orbit()


func _process(_delta: float) -> void:
	_place_on_orbit()


## CLIENT: a replicated pose was just applied (PropSync) — the server's fixed one. Back on the orbit in
## the same call, so it is never drawn there.
func apply_prop_data(_data: Dictionary) -> void:
	if is_inside_tree():
		_place_on_orbit()


## CLIENT: on its orbit, now.
func _place_on_orbit() -> void:
	var pose: Transform3D = orbit_pose_at(Globals.sim_time())
	if pose == Transform3D.IDENTITY:
		return  # site or body not known yet
	var frame: Node = get_parent()
	position = Planet.in_frame_of(frame, pose.origin)
	basis = Planet.basis_in_frame_of(frame, pose.basis)


## Where the station is and how it faces at time [param t], relative to the CENTRE of its body, in the
## body's non-rotating parent frame (as a moon's orbit is given). THE one answer to "where is the station
## now": the client places it from this, and the server — whose station never moves — asks it too, or a
## body leaving the station would be put where the station was at t = 0, a whole orbit away.
## IDENTITY while the site or the body is not known yet.
func orbit_pose_at(t: float) -> Transform3D:
	if _orbit == null and not _resolve_orbit():
		return Transform3D.IDENTITY
	return Transform3D(_orbit.attitude_at(t), _orbit.position_at(t))


## The station [param node] is aboard (itself included), or null.
static func of(node: Node) -> OrbitalStation:
	var walk: Node = node
	while walk != null and not (walk is OrbitalStation):
		walk = walk.get_parent()
	return walk as OrbitalStation


## True while [param world_pos] is close enough to ride with the station (its site's eva_radius_m). A
## plain distance, exact on the server too: the station stands still there, but what is aboard is placed
## relative to it.
func holds(world_pos: Vector3) -> bool:
	var s: StationSite = site()
	var radius: float = s.eva_radius_m if s != null else StationSite.DEFAULT_EVA_RADIUS_M
	return global_position.distance_squared_to(world_pos) <= radius * radius


## Acceleration of a free body beside the station, relative to it: the pull of the orbit that a body let
## go here is on (StationOrbit.hill_acceleration). World coordinates in and out — on the server, where the
## station stands still exactly as those equations assume, so the body is simply integrated as usual with
## this added. ZERO while the orbit is not known.
func relative_acceleration(world_pos: Vector3, world_vel: Vector3) -> Vector3:
	if _orbit == null and not _resolve_orbit():
		return Vector3.ZERO
	var axes: Basis = global_basis.orthonormalized()
	var local_pos: Vector3 = axes.transposed() * (world_pos - global_position)
	var local_vel: Vector3 = axes.transposed() * world_vel
	return axes * StationOrbit.hill_acceleration(local_pos, local_vel, _orbit.mean_motion())


## The description of this station, found by its uuid. Null until the uuid is known.
func site() -> StationSite:
	if _site == null and uuid != "" and uuid != _site_missing_for:
		var body: Planet = Planet.of(get_parent())
		if body != null and body.planet_data != null:
			var system: String = SystemScenes.system_of(body.planet_data.planet_name)
			_site = StationSites.by_uuid(system, uuid)
			if _site == null:
				_site_missing_for = uuid
				push_warning("[Station] no StationSite with uuid %s in system '%s': it will not orbit" % [uuid, system])
	return _site


## The station's name, as players read it.
func display_name() -> String:
	var s: StationSite = site()
	return s.display_name() if s != null else name


## Where a traveller lands, local to the station.
func arrival_position() -> Vector3:
	var marker: Node3D = get_node_or_null(ARRIVAL_NODE) as Node3D
	return marker.position if marker != null else Vector3.ZERO


func _resolve_orbit() -> bool:
	var s: StationSite = site()
	var body: Planet = Planet.of(get_parent())
	if s == null or body == null:
		return false
	_orbit = s.orbit(StationSite.body_props_of(body))
	return true
