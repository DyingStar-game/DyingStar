class_name SystemSandbox
extends Node3D

@export var spawn_node: Node
@export var uuid: String = ""

var is_ready: bool = false

# NE FONCTIONNE QUE PARCE QUE LES POINTS DE SPAWN SONT AUTOUR DE PLANETEA : DOIT RETOURNER LE CENTRE DE LA PLANETE DU POINT DE SPAW
# A ADAPTER POUR LES STATIONS ET VAISSEAUX : RETOURNER LE VECTEUR.UP
var planet_center: Vector3 = Vector3.ZERO

func _ready() -> void:
	is_ready = true

func _physics_process(_delta: float) -> void:
	pass
