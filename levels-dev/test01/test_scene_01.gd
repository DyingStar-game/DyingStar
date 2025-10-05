extends Node3D

@onready var player: CharacterBody3D = $NormalPlayer

func _enter_tree() -> void:
	pass

func _ready() -> void:	
	player.controllability_component = LocalPlayerControllability.new()
	player.controllability_component.entity = player
