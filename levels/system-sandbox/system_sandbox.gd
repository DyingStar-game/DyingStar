class_name SystemSandbox
extends Node3D

## Network uuid of this level root. "" = the world frame: props parented here are published with parent_id "".
@export var uuid: String = ""

var is_ready: bool = false

# NE FONCTIONNE QUE PARCE QUE LES POINTS DE SPAWN SONT AUTOUR DE PLANETEA : DOIT RETOURNER LE CENTRE DE LA PLANETE DU POINT DE SPAW
# A ADAPTER POUR LES STATIONS ET VAISSEAUX : RETOURNER LE VECTEUR.UP
var planet_center: Vector3 = Vector3.ZERO

func _ready() -> void:
	is_ready = true

func _physics_process(_delta: float) -> void:
	pass
