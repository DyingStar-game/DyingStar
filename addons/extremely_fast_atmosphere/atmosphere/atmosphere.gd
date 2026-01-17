@tool
@icon("res://addons/extremely_fast_atmosphere/atmosphere_icon.png")
class_name ExtremelyFastAtmpsphere
extends MeshInstance3D

@export var planet_radius: float:
	set(value):
		planet_radius = value
		_update_atmosphere()


@export var atmosphere_height: float:
	set(value):
		atmosphere_height = value
		_update_atmosphere()


@export var sun_object: Node3D


func _init() -> void:
	# Makes sure this atmosphere mesh and material are not shared if multiple planets are shown
	if material_override and material_override is ShaderMaterial:
		material_override = material_override.duplicate()
	if mesh:
		mesh = mesh.duplicate()


func _ready() -> void:
	set_physics_process(sun_object != null)


func _update_atmosphere():
	if not material_override is ShaderMaterial:
		return
	var mat: ShaderMaterial = material_override
	
	var atmosphere_outer_radius: float = planet_radius + atmosphere_height
	
	var cube_mesh: BoxMesh = mesh
	cube_mesh.size = Vector3.ONE * 2.1 * atmosphere_outer_radius
	
	mat.set_shader_parameter("sea_level", planet_radius)
	mat.set_shader_parameter("atmosphere_radius", planet_radius + atmosphere_height)


func set_sun_position(global_pos: Vector3):
	var delta_pos = global_pos - global_position
	look_at(global_position - delta_pos)


func _physics_process(_delta: float) -> void:
	if sun_object:
		set_sun_position(sun_object.global_position)
