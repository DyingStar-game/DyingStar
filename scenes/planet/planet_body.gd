@tool
class_name Planet
extends Node3D
## Main planet body — root node for every planet instance.
##
## Responsibilities:
##   • Positions itself in the universe via [member spawn_position].
##   • Orchestrates child systems (terrain, atmosphere).
##   • Applies the **client / server split**:
##       – Client: visual terrain + atmosphere, NO collision.
##       – Server: collision shapes only (via [PlanetTerrain]), NO rendering.
##
## Expected children (set up in base_planet.tscn):
##   PlanetTerrain  — quadtree terrain manager
##   (the atmosphere is drawn client-side by AtmosphereRenderer, not by a node here)

## Earth mass in kg — converts orbit_mass_earths to the KG the Kepler solver expects.
const MASS_EARTH := 5.972e24
## System scale factor — must MATCH the service's DISTANCE_FACTOR (import-system.ts). 1 = true 1:1 (real
## distances); it used to be 3 (the system was shrunk to a third). We divide the raw AU by it so our local
## orbit lands where the network placed the body. Flip in lockstep with the service (services PR #25).
const DISTANCE_FACTOR := 1.0

@export var planet_data: PlanetData:
	set(value):
		if Engine.is_editor_hint() and planet_data:
			if planet_data.changed.is_connected(_on_planet_data_changed):
				planet_data.changed.disconnect(_on_planet_data_changed)
		planet_data = value
		if Engine.is_editor_hint() and is_inside_tree():
			if planet_data:
				planet_data.changed.connect(_on_planet_data_changed)
			_setup_planet()
@export var uuid: String = ""

## Colour this body reads as from space — used by the system chart (StarMap), and available to
## anything else that needs to name it at a glance. Derived from the GDD's own description of each
## world rather than picked by eye: Tarsis I's "océan de lave et obsidian surchauffé", Tarsis II's
## sulfur plains and iron sand, Tarsis III's permanent corundum dust storm, Tarsis VIII's tholins.
## Where the GDD gives no description, physics does: methane absorbs red (the ice giant reads blue),
## albedo sets the brightness, and equilibrium temperature separates ice from rock.
## Default is the neutral blue a body with no data gets.
@export var map_color: Color = Color(0.45, 0.72, 1.0)

## What this body is CALLED, for markers and the system chart — never the node name, which carries
## Horizon's code (a planet arrives as "SandBox" but a moon as "P3_M2") and differs between the
## server's tree and the client's. Taken from the GDD: proper name when it has one, catalogue
## designation otherwise, e.g. "Korax - Tarsis III.M1" or plain "Tarsis VI.M1".
## Empty falls back to the node name, so a body nobody has named still shows something.
@export var display_name: String = ""

## True radius in km, for anything that must know the body's SIZE without loading it.
## `planet_data.radius` cannot serve: it holds its 1000 m default in the saved scene and only gets the
## real value at runtime, from apply_chunk_manifest(). Reading a scene file statically — which is how
## the system chart lists bodies it has never spawned — therefore sees a kilometre-wide planet.
## Value from the celestial data (tarsis.json, radius_km). 0 = unknown, callers fall back.
@export var map_radius_km: float = 0.0

## Fraction of the starlight this body reflects, from the celestial data (tarsis.json, albedo). It is
## what turns a moon into a light source: the reflected illumination it sends to a nearby planet is
## (2/3) * albedo * (radius / distance)^2 of the starlight the moon itself receives. 0 = unknown, and
## the body then lights nothing.
@export var surface_albedo: float = 0.0

## Backward compatibility — old scenes export these instead of planet_data.
@export var planet_id: String = ""

@export_group("Rotation")
## Sidereal rotation period in HOURS — 0 means the planet does not spin. Mirrors the `rotation_h`
## column of the celestial database served by resourcesDynamic: SandBox 25 h, Gaea 24 h, Tarsis 5
## 11.74 h. Set a very small value (e.g. 0.05 = a 3-minute day) to watch a full cycle while testing.
##
## These fields mirror the service contract on purpose, so feeding them from the network later is a
## drop-in: same columns, and _apply_spin reproduces the service's own formula
## (rotation-quaternion.ts). NOT covered yet: `tidal_locked` bodies (Tarsis 1 and 8 of the 10 moons),
## whose rotation tracks their orbit instead of a fixed period, and `spin_longitude_rad`, which the
## service currently hardcodes to 0 (no prime meridian, so every body shares the same phase at t=0).
@export var rotation_period_hours: float = 0.0
## Axial tilt in DEGREES about the local Z axis — the `tilt_rad` column, converted from radians.
@export var axial_tilt_deg: float = 0.0
## How many times per second the planet transform is refreshed. 2-3 Hz is plenty (ddurieux) and it
## keeps the cost of carrying the dynamic bodies along (see _carry_dynamic_bodies) affordable.
## ⚠️ A CPU budget knob, never a correctness one. Raising it does NOT reduce the one-step kinematic lag
## described in _carry_dynamic_bodies — that lag is one physics step whatever the rate, so at 60 Hz a
## ~150 m spike once every 20 frames simply becomes a PERMANENT ~7 m offset.
@export var rotation_update_hz: float = 3.0

@export_group("Orbit")
## Orbital elements, RAW as in tarsis.json / the celestial DB (resourcesDynamic) so the data is a
## straight copy. apoapsis/periapsis = 0 means the body does NOT orbit (it keeps its network position).
## The distances are the UNSCALED AU from tarsis.json; _build_orbit divides them by DISTANCE_FACTOR to
## match the service's own import (which shrinks the system but keeps masses raw, so orbits run faster).
## Like rotation_period_hours, these mirror the service contract on purpose — feeding them from the
## network later is a drop-in. Only PLANETS are wired for now; moons keep their network offset and ride
## their planet's orbit (they will orbit on their own once the parent-spin frame is decoupled).
@export var orbit_periapsis_au: float = 0.0
@export var orbit_apoapsis_au: float = 0.0
@export var orbit_inclination_deg: float = 0.0
@export var orbit_ascending_node_deg: float = 0.0
@export var orbit_arg_periapsis_deg: float = 0.0
## Mean anomaly at the elements' epoch (unix t = 0), in degrees — the M0_deg column. The phase then
## advances with sim_time, matching the service which anchors on the same absolute time.
@export var orbit_mean_anomaly_deg: float = 0.0
## This body's own mass, in Earth masses (mass_Me). Negligible next to the primary but kept for fidelity.
@export var orbit_mass_earths: float = 0.0
## Mass of the body this one orbits, in KG: the STAR for a planet (mass_Sun × 1.98892e30), the PLANET
## for a moon. 0 falls back to one solar mass.
@export var orbit_primary_mass_kg: float = 0.0
@export_group("")

## Set by the server before the node enters the tree.
var spawn_position: Vector3 = Vector3.ZERO
## SERVER REBASE: the planet's TRUE universe position, kept as DATA only. On the server each planet
## sits at the ORIGIN of its own physics world (SubViewport.own_world_3d, see server.gd
## create_planet) so Jolt's float32 broadphase keeps metre-scale AABBs — at 3.3e10 m they quantise
## to ±2 km and every query near a dense surface costs ~30x (measured 2026-08; see the
## origin-rebase notes in the commit history).
## Conversions between frames go through server.gd _true_position/_owning_planet. Stays ZERO on
## clients: their scene keeps the astronomic layout, replication is parent-local on both sides.
var orbital_position: Vector3 = Vector3.ZERO
## SERVER REBASE: uuid of the body [member orbital_position] is measured FROM, "" when it is already
## a universe-absolute position. Horizon sends a moon's position RELATIVE to the planet it orbits
## (P3_M1 arrives at ~3e7 m while Tarsis 3 sits at ~3.3e10 m) and carries the tie in parent_id — the
## client resolves it by parenting the moon under its planet, but the server keeps every body at the
## origin of its own physics world, so it must sum the chain instead: server.gd _planet_orbital_abs.
var orbital_parent_uuid: String = ""

## Built from the orbit_* elements in _ready when the body orbits (null otherwise). Owns `position`.
var _orbit: KeplerOrbit = null

## Time since the last spin refresh.
var _spin_accum: float = 0.0

## Runtime-created water sphere (ocean surface).
var _water_sphere: MeshInstance3D

## Runtime-created gravity area (point gravity toward planet center).
var _gravity_area: Area3D

@onready var planet_terrain: PlanetTerrain = $PlanetTerrain if has_node("PlanetTerrain") else null

func _ready() -> void:
	if not Engine.is_editor_hint():
		print("[Planet] _ready: name=%s  spawn_position=%s  position=%s"
				% [name, spawn_position, position])
		# Only apply spawn_position when it was actually set (server path:
		# create_planet assigns it BEFORE add_child). On the client, planets
		# spawn through the generic path: client_channel_data_update() applies
		# the network "positions" BEFORE add_child, and spawn_position stays
		# ZERO — unconditionally assigning it here wiped that position, so
		# every network planet collapsed to (0,0,0) under its parent
		# (tarsis_3_1/4_2 rendered as phantom surfaces INSIDE tarsis_3).
		if spawn_position != Vector3.ZERO:
			position = spawn_position

	if planet_data:
		# Load runtime overrides from the QGIS-exported planet JSON (if set).
		if not planet_data.planet_json.is_empty():
			planet_data.load_from_planet_json()
		# Apply the chunk manifest here too (radius / max_height / etc.) so those
		# values are correct BEFORE _setup_planet builds things that depend on
		# them — gravity area, water sphere. Otherwise they use
		# the default radius (1000 m) and, e.g., the gravity sphere ends up far
		# smaller than the planet, leaving the surface with no gravity.
		# apply_chunk_manifest() is idempotent; PlanetTerrain.initialize() also
		# calls it.
		if not planet_data.chunk_heightmaps_dir.is_empty():
			planet_data.apply_chunk_manifest()
		# Pre-build the detail texture array so it's ready for chunk generation.
		planet_data.get_detail_texture_array()
		# Warm the biome cache on the MAIN thread before any chunk mesh task
		# runs.  Chunk meshes are generated on WorkerThreadPool threads, which
		# all call get_biome_by_type() concurrently; that lazily runs
		# _build_biome_cache(), which CLEARS then repopulates its dictionaries.
		# A worker hitting it mid-build gets null → the corundum override is
		# lost → those chunks bake detail_scale=0 and render untextured
		# (non-deterministic patches, different every launch).  Building it
		# here once, single-threaded, makes the later worker access read-only.
		planet_data.warm_biome_cache()
		if Engine.is_editor_hint() and not planet_data.changed.is_connected(_on_planet_data_changed):
			planet_data.changed.connect(_on_planet_data_changed)
		_setup_planet()
	else:
		print("[Planet] _ready: planet_data is NULL — terrain will not initialize")

	# Celestial motion (runtime only): build the orbit and place the body at its current orbital
	# position immediately, so an orbiting planet never pops from the network spawn position to its
	# computed one on the first physics tick (the local orbit owns `position`, as _apply_spin owns basis).
	#
	# CLIENTS ONLY, and for the SAME reason _physics_process is clients only (see the note there): on
	# the server each planet sits at the ORIGIN of its own physics world so Jolt's float32 broadphase
	# keeps metre-scale AABBs. Placing it on its orbit here put it back out at astronomic range —
	# 7.8e9 m for the innermost body, 9.5e10 m for SandBox, where the f32 ULP is 512 m and 4096 m
	# respectively — so every AABB near the city is inflated by hundreds of metres and every query is
	# handed hundreds of extra candidates. That is the whole 60 -> 6 TPS collapse, AT REST, out of one
	# assignment at boot. The `_physics_process` guard cannot catch it: placing the planet ONCE is
	# enough, and this ran before the first physics frame.
	if not Engine.is_editor_hint() and not OS.has_feature("dedicated_server"):
		_build_orbit()
		if _orbit != null:
			_place_at_time(Globals.sim_time())


# ------------------------------------------------------------------
# Rotation (spin on axis)
# ------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	# The spin is applied on CLIENTS ONLY — the dedicated server keeps a STATIC collision frame. Physics at
	# astronomic coordinates needs a stable frame: rotating the planet-sized StaticBody collision teleports
	# it in Jolt every refresh and breaks CharacterBody contact for every body on the surface (the "everyone
	# bobs" dance). The server therefore never spins. This works WITHOUT desyncing orientation because
	# player/prop rotation is replicated in the planet-LOCAL frame (see player.gd net_set_target /
	# player_server.gd apply+broadcast / player_client.gd send) — a frame-invariant quantity, exactly like
	# positions — so the server (static) and every client (spun) agree on where a body faces. The spin
	# itself is a pure function of absolute time, so all clients land on the SAME orientation: a space
	# observer sees the planet turning and a surface body co-rotates with the ground. Day/night is
	# client-side (PlayerSunLight, player world pos vs the fixed star). Orbital position is separate.
	# The server moves NOTHING celestial — neither the spin nor the orbit — and the two are forbidden
	# for DIFFERENT reasons, which is why they were separated and measured rather than assumed.
	#
	# The SPIN: turning a planet-sized collision frame teleports it in Jolt every refresh and breaks
	# CharacterBody contact for every body on the surface (the "everyone bobs" dance).
	#
	# The ORBIT was tried, and it cost nothing: a player is a CHILD of the planet, so the scene graph
	# moves them together, in the same frame, by the same vector — their relative geometry never
	# changes, and ground contact depends on nothing else. Measured with SandBox at 94.61 million km
	# travelling 33.1 km/s: no effect in game. **Moving a frame is safe; turning one is not.**
	#
	# It stays off anyway, because the server's planets are about to stop living in a shared world at
	# all. Each one is being moved to the ORIGIN of its own physics world so Jolt's float32 broadphase
	# keeps metre-scale AABBs — at 3.3e10 m they quantise to ±2 km, which multiplies every query near a
	# dense surface and collapses the tick rate. Placing a planet anywhere but its own origin hands
	# that straight back, and this file merges CLEANLY into a server that does exactly that, with no
	# conflict for anyone to notice. So the guard lives here rather than in a merge note.
	if Engine.is_editor_hint() or OS.has_feature("dedicated_server"):
		return
	if rotation_period_hours <= 0.0 and _orbit == null:
		return
	# Refresh at a few Hz rather than every tick: the planet carries the terrain colliders and every
	# body standing on it, and each refresh makes Jolt re-insert all of them into the broadphase.
	_spin_accum += delta
	if _spin_accum < 1.0 / maxf(rotation_update_hz, 0.001):
		return
	_spin_accum = 0.0
	_place_at_time(Globals.sim_time())
	_carry_dynamic_bodies(self)

## Place this body's basis (axial spin) and position (orbit) for absolute simulation time `t`.
##
## Both are PURE FUNCTIONS OF TIME, evaluated independently by the server and by every client, so
## neither the rotation nor the orbit travels over the network: all sides land on the same transform as
## long as their clocks agree (Globals.sim_time). Mirrors the celestial service formulas
## (resourcesDynamic: rotation-quaternion.ts and kepler-orbit.ts). Runs at a few Hz in _physics_process
## so the transform is settled before the physics step — this node carries the terrain colliders and
## every body on it (see _carry_dynamic_bodies, called right after).
##
## NOTE: the SPIN writes the LOCAL basis, so a moon parented to a planet would inherit its planet's
## spin — correct only for bodies parented directly to the universe root. Only planets orbit for now;
## revisit the frame when moons spin/orbit on their own.
## [param apply_spin] false drives the ORBIT ALONE, leaving the basis untouched. No caller needs it
## now that the server places nothing, but it stays: it is the knob that made the spin and the orbit
## separable, and that distinction is the part worth keeping.
func _place_at_time(t: float, apply_spin: bool = true) -> void:
	if apply_spin and rotation_period_hours > 0.0:
		# fmod BEFORE scaling to TAU: sim time over a ~25 h period is many revolutions, and folding it
		# back into a single turn first keeps the angle small and precise.
		var turns: float = fmod(t / (rotation_period_hours * 3600.0), 1.0)
		basis = Basis(Vector3.BACK, deg_to_rad(axial_tilt_deg)) * Basis(Vector3.UP, turns * TAU)
	if _orbit != null:
		# A MOON orbits its planet, and it is a CHILD of that planet, whose basis SPINS on the client.
		# Writing the Kepler position straight into `position` would therefore let the planet's day
		# sweep the moon around it once every rotation, on top of its real orbit. Cancelling the
		# parent's basis makes the moon's WORLD offset the Kepler one whatever the parent is doing.
		# Costs nothing for a planet: its parent is the universe root, whose basis is the identity —
		# and nothing on the server either, which never spins anything.
		var frame: Node3D = get_parent() as Node3D
		if frame != null and frame is Planet:
			position = frame.basis.inverse() * _orbit.position_at(t)
		else:
			position = _orbit.position_at(t)


## True when the orbit_* elements describe a real orbit (a periapsis or apoapsis was set).
func has_orbit() -> bool:
	return orbit_apoapsis_au > 0.0 or orbit_periapsis_au > 0.0


## Build the Kepler solver from the raw orbit_* elements (no-op when the body does not orbit). Applies
## the same DISTANCE_FACTOR shrink and deg->rad / Earth-mass conversions the service does at import.
func _build_orbit() -> void:
	if not has_orbit():
		return
	_orbit = KeplerOrbit.new(
			orbit_periapsis_au / DISTANCE_FACTOR,
			orbit_apoapsis_au / DISTANCE_FACTOR,
			deg_to_rad(orbit_inclination_deg),
			deg_to_rad(orbit_ascending_node_deg),
			deg_to_rad(orbit_arg_periapsis_deg),
			deg_to_rad(orbit_mean_anomaly_deg),
			orbit_primary_mass_kg,
			orbit_mass_earths * MASS_EARTH)

## Carry the dynamic bodies standing on the planet along with the spin.
##
## Godot has no notion of a moving reference frame: a RigidBody3D is simulated by Jolt in WORLD
## space, so rotating this node moves the mesh through the scene graph but leaves the physics body
## behind. The collider then drifts away from what the player sees — crates you walk through,
## vehicles with offset collision. So we recompute each body's world pose ourselves and hand it to
## the physics server, the only reliable way to move a body from outside _integrate_forces.
##
## The body's LOCAL pose is the source of truth: it says where the body sits ON the planet, and the
## spin does not change it. Deliberately NOT a delta rotation applied to the body's world pose —
## Godot refreshes that pose from the scene graph for SLEEPING bodies but from the physics state for
## awake ones, so a delta lands once on some bodies and twice on others (which is what made the
## editor-placed, sleeping WindValley rigs drift off the terrain while the crates looked fine).
## Recomputing from the local pose is idempotent, so it cannot double-apply.
##
## Walks the whole subtree except the terrain (whose static colliders follow the scene graph on their
## own, and which holds far too many nodes to visit at this rate), so props carried by a player or
## parented under a structure are carried too, not just the planet's direct children.
##
## ⚠️ CharacterBody3D (the player) is deliberately absent, and adding it would make things WORSE.
## Such a body needs nothing here: the NODE owns its pose, so the scene graph already carries it —
## unlike a RigidBody3D, whose pose the solver rewrites every step, which is the whole reason this
## function exists. And body_set_state is precisely the call the engine already issues by itself on
## NOTIFICATION_TRANSFORM_CHANGED; on a body whose Jolt motion type is KINEMATIC it does not teleport
## anything, it records a target the body then SWEEPS to during the next step. We would gain nothing
## and sweep a capsule across ~150 m of world at several km/s on every refresh.
## What lags for such a body is its JOLT pose, by exactly one step — so never test a player's presence
## with area-versus-body across this frame. Detection zones live on the `zone` layer and the player's
## own AreaDetector does the looking (Player.connect_area_detect, ScreenZone).
## NB: "kinematic" here is a Jolt MOTION TYPE, not a node class — a RigidBody3D frozen in
## FREEZE_MODE_KINEMATIC (PropNet.apply_ride_freeze_mode, for cargo riding a truck) is kinematic too.
func _carry_dynamic_bodies(node: Node) -> void:
	for child: Node in node.get_children():
		if child == planet_terrain:
			continue
		if child is RigidBody3D:
			_carry_body(child)
		_carry_dynamic_bodies(child)

## Move one body's physics pose onto the spun frame, as cheaply as the body's state allows.
##
## Bodies the settle-culler froze are SKIPPED: their collision shapes are disabled, so they are out
## of Jolt's broadphase entirely and their collider cannot be hit — moving it is pure cost. Their
## mesh still follows the scene graph, and the culler pushes the physics pose back when it wakes them
## up near a player. Teleporting them here would also WAKE them several times a second, undoing the
## freeze that the whole server-side physics budget depends on.
##
## A teleport activates a body in Jolt, so one that was asleep is put straight back to sleep —
## otherwise every resting crate on the planet wakes up on every refresh.
func _carry_body(body: RigidBody3D) -> void:
	if body.get_meta("_culled_frozen", false):
		return
	var was_asleep: bool = body.sleeping
	var rid: RID = body.get_rid()
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, body.global_transform)
	if was_asleep:
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_SLEEPING, true)

## Local solar time at [param world_pos], in hours in [0, 24) — 12 h is local noon (the star is at
## its highest), 0 h is midnight. Returns -1.0 when it is not defined: planet not spinning, no star
## in the system, or the point sits on the spin axis (at a pole every meridian meets, so there is no
## local time).
##
## Pure geometry, no clock and no network — this is a sundial: the hour is the angle, about the spin
## axis, between the observer's meridian and the one facing the star. Both sides of a multiplayer
## session therefore agree by construction.
##
## The planet's day is split into 24 hours whatever its real period, so 12:00 means "star at its
## highest" on every planet; SandBox's 25 h day just makes each of its hours longer than an Earth one.
func get_local_solar_time(world_pos: Vector3) -> float:
	if rotation_period_hours <= 0.0:
		return -1.0
	var star: Node3D = _find_sun()
	if star == null:
		return -1.0
	# Spin axis in world space: _apply_spin turns about the LOCAL Y, so the tilted local Y is the axis.
	var axis: Vector3 = global_basis.y.normalized()
	# Both directions are taken from the planet CENTRE: the sub-stellar point is defined by the
	# planet->star direction, the observer's meridian by the centre->observer direction.
	var to_star: Vector3 = star.global_position - global_position
	var to_obs: Vector3 = world_pos - global_position
	# Drop the along-axis part of each: what is left are the two meridians, in the equatorial plane.
	var noon: Vector3 = to_star - axis * to_star.dot(axis)
	var here: Vector3 = to_obs - axis * to_obs.dot(axis)
	# Relative tests, because these vectors are astronomically long: a projection that collapsed to
	# almost nothing means the direction was along the axis, and the angle would be meaningless.
	if noon.length() < to_star.length() * 0.001 or here.length() < to_obs.length() * 0.001:
		return -1.0
	noon = noon.normalized()
	here = here.normalized()
	# Signed angle from the noon meridian to ours, measured about the axis: 0 = facing the star.
	var angle: float = atan2(axis.dot(noon.cross(here)), noon.dot(here))
	return fposmod(angle / TAU * 24.0 + 12.0, 24.0)


# ------------------------------------------------------------------
# Setup
# ------------------------------------------------------------------

func _setup_planet() -> void:
	_setup_water_sphere()
	_setup_gravity()

	if planet_terrain:
		print("[Planet] _setup_planet: initializing terrain (server=%s)" % _is_server())
		planet_terrain.initialize(planet_data, _is_server())
	else:
		print("[Planet] _setup_planet: planet_terrain is NULL (no $PlanetTerrain child)")

	# The atmosphere is no longer a node on the planet: AtmosphereRenderer draws it from the player's
	# side, out of this body's AtmosphereProfile, so one model serves the ground and the orbit alike.
	# A leftover "Atmosphere" child from the old addon would just render a second, contradictory halo.
	if not Engine.is_editor_hint() and has_node("Atmosphere"):
		$Atmosphere.queue_free()


func _setup_water_sphere() -> void:
	# Remove any previously created water sphere (e.g. when planet_data changes
	# in the editor).
	if _water_sphere:
		_water_sphere.queue_free()
		_water_sphere = null

	if not planet_data or not planet_data.has_ocean:
		return

	# Server never renders.
	if _is_server():
		return

	# Resolve the ocean material — prefer the material from the
	# "maritime_river-ocean" biome definition if available, otherwise
	# fall back to a preloaded default.
	var ocean_material: Material
	for biome in planet_data.biome_definitions:
		if biome is BiomeDefinition and biome.is_liquid and biome.terrain_material_override:
			ocean_material = biome.terrain_material_override
			break

	if ocean_material == null:
		# Attempt to load the bundled ocean surface material.
		var default_path := "res://assets/materials/planet/ocean_surface.tres"
		if ResourceLoader.exists(default_path):
			ocean_material = load(default_path) as Material
		else:
			push_warning("[Planet] has_ocean=true but no ocean material found — skipping water sphere")
			return

	# Duplicate so we can set per-planet shader parameters without affecting the
	# shared resource.
	ocean_material = ocean_material.duplicate() as Material

	# Configure shader uniforms to match this planet's dimensions.
	var water_radius: float = planet_data.radius + planet_data.water_level
	if ocean_material is ShaderMaterial:
		var sm := ocean_material as ShaderMaterial
		sm.set_shader_parameter("planet_radius", water_radius)
		sm.set_shader_parameter("water_level_offset", 0.0)

	# Build the water sphere mesh.
	# Segment count must be high enough for vertex-displaced waves to look
	# smooth. 128 radial / 64 rings is a good balance.
	var sphere := SphereMesh.new()
	sphere.radius = water_radius
	sphere.height = water_radius * 2.0
	# Segment count must be high enough that the chord error (how far flat
	# triangles dip below the true sphere between vertices) stays well below
	# the terrain depression depth.  At R ≈ 2 M m:  512 → ~40 m chord error.
	sphere.radial_segments = 512
	sphere.rings = 256

	_water_sphere = MeshInstance3D.new()
	_water_sphere.name = "WaterSphere"
	_water_sphere.mesh = sphere
	_water_sphere.material_override = ocean_material
	_water_sphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Render the water after opaque terrain so alpha-blending works correctly.
	_water_sphere.sorting_offset = 1.0

	add_child(_water_sphere)
	print("[Planet] Water sphere created — radius=%.1f m  segments=%d  rings=%d" % [water_radius, sphere.radial_segments, sphere.rings])
	print("[Planet]   mesh AABB = %s" % str(sphere.get_aabb()))
	print("[Planet]   visible=%s  material=%s" % [str(_water_sphere.visible), str(_water_sphere.material_override)])


func _setup_gravity() -> void:
	if _gravity_area:
		_gravity_area.queue_free()
		_gravity_area = null

	if not planet_data or not planet_terrain:
		return

	# Skip in editor — gravity is only needed at runtime.
	if Engine.is_editor_hint():
		return

	_gravity_area = Area3D.new()
	_gravity_area.name = "PlanetGravity"
	_gravity_area.add_to_group("gravity")
	# Sit on the `zone` layer so the player's AreaDetector (which scans `zone`) detects it and
	# applies gravity to the player; routed by the "gravity" group.
	_gravity_area.collision_layer = 1 << (Globals.LAYER_ZONE - 1)
	_gravity_area.gravity_space_override = Area3D.SPACE_OVERRIDE_REPLACE
	_gravity_area.gravity_point = true
	_gravity_area.gravity = planet_data.surface_gravity
	_gravity_area.gravity_point_unit_distance = planet_data.radius
	# Apply gravity to every solid RigidBody (world|player|vehicle|prop). Without this the area
	# defaults to scanning `world` only, so props/vehicles on their own layers would float.
	_gravity_area.collision_mask = Globals.MASK_SOLID

	# The gravity sphere covers the terrain plus the configurable gravity_reach.
	# gravity_reach is independent of the atmosphere shell — even airless bodies
	# (moons, asteroids) have gravitational pull above their surface.
	var gravity_reach: float = planet_data.gravity_reach + planet_data.max_height
	var shape := SphereShape3D.new()
	shape.radius = planet_data.radius + gravity_reach
	var col := CollisionShape3D.new()
	col.shape = shape
	_gravity_area.add_child(col)

	planet_terrain.add_child(_gravity_area)


# ------------------------------------------------------------------
# Utilities
# ------------------------------------------------------------------

## Altitude of `world_pos` above this planet's terrain surface (~0 at ground level, negative below it).
## A surface point sits at radius + terrain_height, so subtracting only the base radius reads kilometres
## too high on a body with relief; this samples the heightmap for the real ground. Used by the altitude
## readout and the celestial-marker distances.
## Planet-LOCAL (body-fixed) unit direction of a world point — the frame the heightmap tiles, the
## HEALPix chunk keys and the collision bodies all live in. Vector3.ZERO at the centre, where no
## direction exists.
##
## THE single conversion. It used to be written out at three call sites with TWO different formulas —
## the altitude and lon/lat orthonormalised the basis, the server's chunk pinning did not — so a
## scaled or skewed basis would have had them resolve to neighbouring tiles. Which matters more than
## it sounds: whether the ground is loaded and where the ground IS must be answered about the same
## chunk, or a body waits on terrain nobody asked for.
##
## Body-fixed on purpose: the planet spins, so a world-frame direction drifts off its tile.
func local_dir_of(world_pos: Vector3) -> Vector3:
	var to_pos: Vector3 = world_pos - global_position
	if to_pos.length() < 0.001:
		return Vector3.ZERO
	return (global_basis.orthonormalized().inverse() * to_pos).normalized()


func surface_altitude_of(world_pos: Vector3) -> float:
	if planet_data == null:
		return 0.0
	var to_pos: Vector3 = world_pos - global_position
	var centre_dist: float = to_pos.length()
	if centre_dist < 0.001:
		return -planet_data.radius
	# The heightmap lives in the planet's LOCAL (spinning) frame, so sample the local direction.
	var terrain_height: float = planet_data.sample_height_for_direction(local_dir_of(world_pos))
	return centre_dist - planet_data.radius - terrain_height


## Longitude/latitude (degrees, EPSG:4326) of `world_pos` on this planet. Uses the SAME body-fixed local
## direction the heightmap is sampled with (surface_altitude_of), so it matches the terrain geography and
## the editor_goto_* coordinates. Body-fixed means a fixed ground point keeps its lon/lat as the planet
## spins (global_basis.inverse() undoes the spin). Returns Vector2(lon, lat).
func lonlat_of(world_pos: Vector3) -> Vector2:
	var local_dir: Vector3 = local_dir_of(world_pos)
	if local_dir.is_zero_approx():
		return Vector2.ZERO
	return HEALPix.vec2lonlat(local_dir)


func _is_server() -> bool:
	if Engine.is_editor_hint():
		return false
	if GameOrchestrator:
		return GameOrchestrator.is_server()
	return false


func _on_planet_data_changed() -> void:
	if Engine.is_editor_hint() and is_inside_tree() and planet_data:
		_setup_planet()


func _find_sun() -> Node3D:
	## Walk siblings of the planet in the universe scene looking for the star.
	var parent := get_parent()
	if parent == null:
		return null
	for child in parent.get_children():
		if child == self:
			continue
		# The star scene is a MeshInstance3D named "Star"
		if child is MeshInstance3D and child.name.to_lower().contains("star"):
			return child
	return null


## Called by the network layer when synced data arrives (no-op by default).
func client_channel_data_update(data: Dictionary) -> void:
	# When this body orbits locally, the Kepler solver OWNS `position` (server and client agree via
	# sim_time), so the network position is ignored here — exactly as the network rotations are ignored
	# below. Non-orbiting bodies (moons for now) still take their network position as before.
	if not has_orbit():
		if data.has("positions"):
			position = Vector3(
				data["positions"][0]["x"],
				data["positions"][0]["y"],
				data["positions"][0]["z"]
			)
		elif data.has("position"):
			# GORC zone events (client path) carry a SINGULAR "position" dict —
			# _standardize_object passes zone_data through as object_data. Without
			# this branch a network-spawned planet never applies its position and
			# stays at (0,0,0) under its parent: tarsis_3_1/4_2 then sit CONCENTRIC
			# inside tarsis_3, rendering a phantom uncarved surface over the real
			# terrain (hiding the corundum cracks players then fall into).
			position = Vector3(
				data["position"]["x"],
				data["position"]["y"],
				data["position"]["z"]
			)
	if data.has("rotations"):
		# NOTE: network sends rotations as quaternions {w, x, y, z}. Previously
		# parsed wrongly as Euler (x, y, z) which caused a ~10° client-only tilt
		# of the planet/system root, producing player movement drift relative to
		# the server. The server does NOT currently apply these rotations to its
		# own scene tree (the universe is loaded statically), so applying them on
		# the client too produces a parent-basis mismatch and movement drift.
		# Skip until orbital rotation is handled symmetrically on both sides.
		pass

## Called by the network layer when the parent node changes.
func client_parent_change(_new_parent: Node) -> void:
	pass
