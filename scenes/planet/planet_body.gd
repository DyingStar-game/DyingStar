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
##   Atmosphere      — (optional) instance of extremely_fast_atmosphere

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
@export var rotation_update_hz: float = 3.0

## Set by the server before the node enters the tree.
var spawn_position: Vector3 = Vector3.ZERO

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
		# (tarsis_4_1/4_2 rendered as phantom surfaces INSIDE tarsis_4).
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


# ------------------------------------------------------------------
# Rotation (spin on axis)
# ------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or rotation_period_hours <= 0.0:
		return
	# Refresh at a few Hz rather than every tick: the planet carries the terrain colliders and every
	# body standing on it, and each refresh makes Jolt re-insert all of them into the broadphase.
	_spin_accum += delta
	if _spin_accum < 1.0 / maxf(rotation_update_hz, 0.001):
		return
	_spin_accum = 0.0
	_apply_spin()

## Spin the planet on its axis.
##
## The angle is a PURE FUNCTION OF ABSOLUTE TIME, evaluated independently by the server and by every
## client, so the rotation never travels over the network: both sides land on the same basis as long
## as their clocks agree. Mirrors the celestial service formula (resourcesDynamic,
## rotation-quaternion.ts): tilt about local Z, then spin about local Y. Runs in _physics_process so
## the transform is settled before the physics step — this node carries the terrain colliders.
##
## Only the basis is written; the orbital position stays whatever the network set.
## NOTE: this is the LOCAL basis, so a moon would inherit its planet's spin — correct only for bodies
## parented directly to the universe root. Revisit when moons start spinning.
func _apply_spin() -> void:
	# fmod BEFORE scaling to TAU: unix time over a ~25 h period is some 20 000 revolutions, and
	# folding that back into a single turn first keeps the angle small and precise.
	var turns: float = fmod(Time.get_unix_time_from_system() / (rotation_period_hours * 3600.0), 1.0)
	basis = Basis(Vector3.BACK, deg_to_rad(axial_tilt_deg)) * Basis(Vector3.UP, turns * TAU)
	_carry_dynamic_bodies(self)

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

	# Atmosphere — client only, runtime only
	if not Engine.is_editor_hint() and has_node("Atmosphere"):
		if _is_server():
			# Server has no use for the atmosphere — remove it to avoid
			# PlaceholderMaterial errors from the headless renderer.
			$Atmosphere.queue_free()
		else:
			var atmo: Node = $Atmosphere
			atmo.planet_radius = planet_data.radius
			atmo.atmosphere_height = planet_data.atmosphere_height
			# Try to find the sun (star) in the parent scene
			var sun := _find_sun()
			if sun:
				atmo.sun_object = sun


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
	# gravity_reach is independent of atmosphere_height — even airless bodies
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
func surface_altitude_of(world_pos: Vector3) -> float:
	if planet_data == null:
		return 0.0
	var to_pos: Vector3 = world_pos - global_position
	var centre_dist: float = to_pos.length()
	if centre_dist < 0.001:
		return -planet_data.radius
	# The heightmap lives in the planet's LOCAL (spinning) frame, so sample the local direction.
	var local_dir: Vector3 = (global_basis.orthonormalized().inverse() * to_pos).normalized()
	var terrain_height: float = planet_data.sample_height_for_direction(local_dir)
	return centre_dist - planet_data.radius - terrain_height


## Longitude/latitude (degrees, EPSG:4326) of `world_pos` on this planet. Uses the SAME body-fixed local
## direction the heightmap is sampled with (surface_altitude_of), so it matches the terrain geography and
## the editor_goto_* coordinates. Body-fixed means a fixed ground point keeps its lon/lat as the planet
## spins (global_basis.inverse() undoes the spin). Returns Vector2(lon, lat).
func lonlat_of(world_pos: Vector3) -> Vector2:
	var to_pos: Vector3 = world_pos - global_position
	if to_pos.length() < 0.001:
		return Vector2.ZERO
	var local_dir: Vector3 = (global_basis.orthonormalized().inverse() * to_pos).normalized()
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
		# stays at (0,0,0) under its parent: tarsis_4_1/4_2 then sit CONCENTRIC
		# inside tarsis_4, rendering a phantom uncarved surface over the real
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
