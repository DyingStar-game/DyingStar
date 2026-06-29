@tool
class_name Planet
extends Node3D
## Main planet body — root node for every planet instance.
##
## Responsibilities:
##   • Positions itself in the universe via [member spawn_position].
##   • Orchestrates child systems (terrain, atmosphere, far-LOD sphere).
##   • Applies the **client / server split**:
##       – Client: visual terrain + atmosphere + far-LOD sphere, NO collision.
##       – Server: collision shapes only (via [PlanetTerrain]), NO rendering.
##
## Expected children (set up in base_planet.tscn):
##   PlanetTerrain  — quadtree terrain manager
##   FarLODSphere   — simple sphere with colormap for ultra-far LOD
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

## Set by the server before the node enters the tree.
var spawn_position: Vector3 = Vector3.ZERO

## Runtime-created water sphere (ocean surface).
var _water_sphere: MeshInstance3D

## Runtime-created gravity area (point gravity toward planet center).
var _gravity_area: Area3D

@onready var planet_terrain: PlanetTerrain = $PlanetTerrain if has_node("PlanetTerrain") else null
@onready var far_lod_sphere: MeshInstance3D = $FarLODSphere if has_node("FarLODSphere") else null


func _ready() -> void:
	if not Engine.is_editor_hint():
		print("[Planet] _ready: name=%s  spawn_position=%s" % [name, spawn_position])
		position = spawn_position

	if planet_data:
		# Load runtime overrides from the QGIS-exported planet JSON (if set).
		if not planet_data.planet_json.is_empty():
			planet_data.load_from_planet_json()
		# Pre-build the detail texture array so it's ready for chunk generation.
		planet_data.get_detail_texture_array()
		if Engine.is_editor_hint() and not planet_data.changed.is_connected(_on_planet_data_changed):
			planet_data.changed.connect(_on_planet_data_changed)
		_setup_planet()
	else:
		print("[Planet] _ready: planet_data is NULL — terrain will not initialize")


# ------------------------------------------------------------------
# Setup
# ------------------------------------------------------------------

func _setup_planet() -> void:
	_setup_far_lod_sphere()
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


func _setup_far_lod_sphere() -> void:
	if not far_lod_sphere or not planet_data:
		return

	if _is_server() or Engine.is_editor_hint():
		# Server never renders; editor shows the LOD 0 terrain preview instead.
		far_lod_sphere.visible = false
		return

	# Build a low-poly sphere matching the planet radius
	var sphere := SphereMesh.new()
	sphere.radius = planet_data.radius
	sphere.height = planet_data.radius * 2.0
	sphere.radial_segments = 64
	sphere.rings = 32
	far_lod_sphere.mesh = sphere

	# Apply the QGIS-exported colour map as the albedo
	if planet_data.colormap:
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = planet_data.colormap
		mat.cull_mode = BaseMaterial3D.CULL_BACK
		far_lod_sphere.material_override = mat

	far_lod_sphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


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
