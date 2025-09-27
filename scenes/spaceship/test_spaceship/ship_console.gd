class_name Interactable
extends Area3D

signal interacted()

@export var label = "Interact"

func interact(interactor: Node = null):
	emit_signal("interacted", interactor)
