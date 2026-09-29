class_name Mannequin
extends Node3D
## A figure on the menu stage: the player's own model (human_puppet, the Puppet of player.tscn)
## playing one animation forever — idle, talking, mining, dancing, or walking a small circle. Not an
## NPC, not a player: no network, no physics, no controller; its CharacterAnimator is never set up,
## so it costs nothing, and the animation pauses while off screen.
##
## An instance of mannequin.tscn, placed in menu_stage_world.tscn: move it, turn it (it faces its
## -Z, the arrow of the editor gizmo), pick its clip in the inspector.

## The walk clip is tuned for 1 m/s (CharacterAnimator.WALK_REF_SPEED): feet do not slide at it.
const WALK_SPEED : float = 1.0

## A clip of the humanoid library: Idle, Idle_Talking, Idle_FoldArms, Idle_TalkingPhone,
## Idle_LookAround, Mining, GroundSit_Idle, Sitting_Idle, Dance, Celebration, Yes, Push…
@export var clip : StringName = &"Idle"
## > 0: walks a circle of this radius around its own origin instead of playing `clip` on the spot.
@export var walk_radius : float = 0.0

var _anim : AnimationPlayer
var _playing : StringName
var _angle : float = 0.0

@onready var _puppet : Node3D = $Puppet


func _ready() -> void:
	_anim = _puppet.get_node("AnimationPlayer")
	_playing = &"Walk" if walk_radius > 0.0 else clip
	if not _anim.has_animation(_playing):
		push_warning("Mannequin %s: no clip '%s'" % [name, _playing])
		return
	_anim.play(_playing)
	# Out of step with its neighbours: a crowd breathing in unison reads as a machine.
	_anim.seek(randf() * _anim.current_animation_length, true)
	_anim.speed_scale = randf_range(0.9, 1.1)
	# One-shot clips (a celebration, a nod) loop too — without touching the SHARED library's loop mode.
	_anim.animation_finished.connect(func(_done: StringName) -> void: _anim.play(_playing))
	_angle = randf() * TAU
	set_process(walk_radius > 0.0)
	var on_screen := VisibleOnScreenNotifier3D.new()
	on_screen.aabb = AABB(Vector3(-1.0 - walk_radius, 0.0, -1.0 - walk_radius),
		Vector3(2.0 + 2.0 * walk_radius, 2.0, 2.0 + 2.0 * walk_radius))
	on_screen.screen_exited.connect(_anim.pause)
	on_screen.screen_entered.connect(func() -> void: _anim.play(_playing))
	add_child(on_screen)


func _process(delta: float) -> void:
	_angle = fposmod(_angle + WALK_SPEED / walk_radius * delta, TAU)
	_puppet.position = Vector3(cos(_angle), 0.0, sin(_angle)) * walk_radius
	# Facing the way it walks: the tangent of the circle.
	var along := Vector3(-sin(_angle), 0.0, cos(_angle))
	_puppet.rotation.y = atan2(along.x, along.z)
