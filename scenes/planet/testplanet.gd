@tool
class_name Planet
extends Node3D

signal hs_server_prop_move

@export var planet_id = "planet"

@export_tool_button("update") var on_update = update_planet
@export_tool_button("pack biomes") var on_pack_biomes = pack_biomes

@export var planet_settings: PlanetSettings

@export var uuid: String = ""

var spawn_position: Vector3 = Vector3.ZERO

@onready var planet_gravity: PhysicsGrid = $PlanetTerrain/PlanetGravity
@onready var planet_terrain: PlanetTerrain = $PlanetTerrain
@onready var atmosphere: ExtremelyFastAtmpsphere = $Atmosphere
@onready var water_surface: MeshInstance3D = $WaterSurface


func _enter_tree() -> void:
	if Engine.is_editor_hint(): return
	global_position = spawn_position
	if not OS.has_feature("dedicated_server") and not Engine.is_editor_hint():
		$Atmosphere.sun_object = get_tree().current_scene.get_node("Star/DirectionalLight3D")


func _ready() -> void:
	update_planet()

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint(): return
	# planet_terrain.rotation.y += 0.001 * delta
	# print(transform.basis)
	# global_position = Vector3(global_position[0] + 100, global_position[1], global_position[2])
	# rotate_y(0.1)
	# look_at(global_transform.origin + vector, Vector3.UP)

	# rotate this Node3D around the world origin (Vector3.ZERO) about the Y axis
	#var angle = 0.000001 * delta
	var angle = 0.0000000001 * delta
	var origin = global_position - Vector3(18999498785.9, 0.0, 0.0)
	var rot = Basis(Vector3.UP, angle)

	var gt = global_transform
	gt.basis = rot * gt.basis
	gt.origin = rot * (gt.origin - origin) + origin
	global_transform = gt

	# if GameOrchestrator.is_server():
	# 	emit_signal("hs_server_prop_move", uuid, global_position, global_rotation, "planet")

func update_planet():
	planet_gravity.gravity_point_unit_distance = planet_settings.radius
	var shape = planet_gravity.get_node("CollisionShape3D").shape as SphereShape3D
	shape.radius = planet_settings.radius + planet_settings.atmosphere_height

	planet_terrain.radius = planet_settings.radius
	planet_terrain.terrain_material = planet_settings.terrain_material
	planet_terrain.terrain_settings = planet_settings.terrain_settings

	atmosphere.atmosphere_height = planet_settings.atmosphere_height
	atmosphere.planet_radius = planet_settings.radius
	
	if planet_settings.has_ocean:
		var watermesh = water_surface.mesh as SphereMesh
		watermesh.radius = planet_settings.radius + planet_settings.sea_level
		watermesh.height = (planet_settings.radius + planet_settings.sea_level) * 2
		water_surface.show()
	else:
		water_surface.hide()
	

	planet_terrain.trigger_update()

func _pack_textures(textures: Array[CompressedTexture2D]) -> Texture2DArray:
	var tex_array = Texture2DArray.new()
	var images: Array[Image] = []
	for tex in textures:
		images.push_back(tex.get_image())
	tex_array.create_from_images(images)
	return tex_array

func pack_biomes():
	print("packing...")
	var biome_albedo = _pack_textures(planet_settings.terrain_settings.biomes_albedo)
	ResourceSaver.save(biome_albedo, "res://assets/textures/biomes_packed/"+ planet_id +"_albedo_array.res")
	
	var biome_normal = _pack_textures(planet_settings.terrain_settings.biomes_normal)
	ResourceSaver.save(biome_normal, "res://assets/textures/biomes_packed/"+ planet_id +"_normal_array.res")