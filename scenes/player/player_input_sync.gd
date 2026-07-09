class_name PlayerInput

extends MultiplayerSynchronizer

@export var move_direction: Vector2
@export var mouse_motion: Vector2
@export var sprint: bool
@export var jump: bool

@onready var player = get_parent() as Player

func _enter_tree() -> void:
	set_multiplayer_authority(str(get_parent().name).to_int())

func _unhandled_input(_event: InputEvent) -> void:
	if not is_multiplayer_authority(): return

func _physics_process(_delta: float) -> void:
	if not is_multiplayer_authority(): return

	var dir = Input.get_vector(player.MOVE_LEFT, player.MOVE_RIGHT, player.MOVE_FORWARD, player.MOVE_BACK)
	if dir:
		move_direction = dir
	else:
		move_direction = Vector2.ZERO

	sprint = Input.is_action_pressed(player.SPRINT)
	jump = Input.is_action_just_pressed(player.JUMP)
