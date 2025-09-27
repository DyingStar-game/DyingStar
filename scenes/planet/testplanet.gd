@tool
class_name Planet
extends Node3D

@export_tool_button("update") var on_update = update_planet

@export var planet_settings: PlanetSettings

var spawn_position: Vector3 = Vector3.ZERO

@onready var planet_gravity: PhysicsGrid = $PlanetTerrain/PlanetGravity
@onready var planet_terrain: PlanetTerrain = $PlanetTerrain
@onready var atmosphere: ExtremelyFastAtmpsphere = $Atmosphere
@onready var water_surface: MeshInstance3D = $WaterSurface

func _enter_tree() -> void:
	global_position = spawn_position
	if not OS.has_feature("dedicated_server"):
		$Atmosphere.sun_object = get_tree().current_scene.get_node("Star/DirectionalLight3D")


func _ready() -> void:
	update_planet()

func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint(): return
	#planet_terrain.rotation.y += 0.001 * delta

func update_planet():
	planet_gravity.gravity_point_unit_distance = planet_settings.radius
	var shape = planet_gravity.get_node("CollisionShape3D").shape as SphereShape3D
	shape.radius = planet_settings.radius + planet_settings.atmosphere_height

	planet_terrain.radius = planet_settings.radius
	planet_terrain.terrain_material = planet_settings.terrain_material
	planet_terrain.terrain_settings = planet_settings.terrain_settings

	atmosphere.atmosphere_height = planet_settings.atmosphere_height
	atmosphere.planet_radius = planet_settings.radius + 600

	if planet_settings.has_ocean:
		var watermesh = water_surface.mesh as SphereMesh
		watermesh.radius = planet_settings.radius + planet_settings.sea_level
		watermesh.height = (planet_settings.radius + planet_settings.sea_level) * 2
		water_surface.show()
	else:
		water_surface.hide()

	planet_terrain.trigger_update()
