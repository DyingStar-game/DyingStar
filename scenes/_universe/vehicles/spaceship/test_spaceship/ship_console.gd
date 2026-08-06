class_name Interactable
extends Area3D

signal interacted()

@export var label = "Interact"

func _ready() -> void:
	add_to_group("interactable")
	# Passive look-at target on `interactable`, detected by the player's InteractRay (collide_with_areas).
	collision_layer = 1 << (Globals.LAYER_INTERACTABLE - 1)  # interactable
	collision_mask = 0
	monitoring = false
	monitorable = true

func interact(interactor: Node = null):
	emit_signal("interacted", interactor)
