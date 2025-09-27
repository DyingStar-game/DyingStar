extends Node3D

@export var spawn_node: Node

var is_ready: bool = false
var spawn_points_list: Array[Vector3]:
	set(value):
		spawn_points_list = value
	get:
		return spawn_points_list

# NE FONCTIONNE QUE PARCE QUE LES POINTS DE SPAWN SONT AUTOUR DE PLANETEA : DOIT RETOURNER LE CENTRE DE LA PLANETE DU POINT DE SPAW
# A ADAPTER POUR LES STATIONS ET VAISSEAUX : RETOURNER LE VECTEUR.UP
var planet_center: Vector3 = Vector3.ZERO

func _ready() -> void:
	is_ready = true

	if has_node("PlayerSpawnPointsList"):
		for child in get_node("PlayerSpawnPointsList").get_children():
			spawn_points_list.append(child.global_position)

func assign_spawn_informations() -> void:
	planet_center = get_node("Sandbox").global_position


func _physics_process(_delta: float) -> void:
	pass
