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

func _enter_tree() -> void:
	if Engine.is_editor_hint(): return
	global_position = spawn_position
	if not OS.has_feature("dedicated_server") and not Engine.is_editor_hint():
		$Atmosphere.sun_object = get_tree().current_scene.get_node("Star/DirectionalLight3D")

func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint(): return


func _ready() -> void:
	update_planet()

	# if GameOrchestrator.is_server():
	# 	emit_signal("hs_server_prop_move", uuid, global_position, global_rotation, "planet")

func update_planet():
	var planet_gravity: PhysicsGrid = $PlanetTerrain/PlanetGravity
	var planet_terrain: PlanetTerrain = $PlanetTerrain
	var atmosphere: ExtremelyFastAtmpsphere = $Atmosphere
	var water_surface: MeshInstance3D = $WaterSurface
	var clouds: MeshInstance3D = $Clouds

	planet_gravity.gravity_point_unit_distance = planet_settings.radius
	var shape = planet_gravity.get_node("CollisionShape3D").shape as SphereShape3D
	shape.radius = planet_settings.radius + planet_settings.atmosphere_height

	planet_terrain.radius = planet_settings.radius
	planet_terrain.terrain_material = planet_settings.terrain_material
	planet_terrain.terrain_settings = planet_settings.terrain_settings

	atmosphere.atmosphere_height = planet_settings.atmosphere_height
	atmosphere.planet_radius = planet_settings.radius



	planet_terrain.terrain_material.set_shader_parameter("layer_count", planet_terrain.terrain_settings.biomes_albedo.size())

	if planet_settings.has_ocean:
		var watermesh = water_surface.mesh as SphereMesh
		watermesh.radius = planet_settings.radius + planet_settings.sea_level
		watermesh.height = (planet_settings.radius + planet_settings.sea_level) * 2
		water_surface.show()
	else:
		water_surface.hide()

	if planet_settings.has_clouds:
		clouds.show()
		var cloud_mesh = clouds.mesh as SphereMesh
		var cloud_mesh_radius = planet_settings.radius + planet_settings.cloud_height
		cloud_mesh.height = cloud_mesh_radius * 2
		cloud_mesh.radius = cloud_mesh_radius
	else:
		clouds.hide()

	planet_terrain.trigger_update()

	if Engine.is_editor_hint():
		update_spawn_points()

func update_spawn_points():
	var planet_terrain: PlanetTerrain = $PlanetTerrain

	for spawn_point: Marker3D in planet_terrain.get_node("PlayerSpawnPointsList").get_children():
		var normalized_pos = spawn_point.position.normalized()
		var surface_pos = planet_terrain.get_height(normalized_pos)
		var space = get_world_3d().direct_space_state
		var param = PhysicsRayQueryParameters3D.new()
		param.from = surface_pos + normalized_pos * 100
		param.to = surface_pos

		var spawn_pos = surface_pos
		var collision = space.intersect_ray(param)
		if collision:
			spawn_pos = collision["position"]

		spawn_point.position = spawn_pos + normalized_pos * 3
		spawn_point.global_transform = planet_terrain.align_with_y(spawn_point.global_transform, normalized_pos)

func get_spawn_point() -> Transform3D:
	var planet_terrain: PlanetTerrain = $PlanetTerrain
	var spawn_point = planet_terrain.get_node("PlayerSpawnPointsList").get_children().front() as Marker3D
	return spawn_point.transform

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
