extends Area3D

## Time (s) to fade the zone's sound in when a player enters it.
@export var fade_in_duration := 2.0
## Time (s) to fade the sound out (then stop it) when the player leaves.
@export var fade_out_duration := 3.0
## Volume (dB) reached inside the zone, faded in from -80 dB.
@export var target_volume_db := -50.0

var _tween: Tween

@onready var audio := $AudioStreamPlayer

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _on_body_entered(body: Node3D) -> void:
	if not body.is_in_group("player"):
		return

	audio.volume_db = -80.0
	audio.play()

	_start_fade(target_volume_db, fade_in_duration)


func _on_body_exited(body: Node3D) -> void:
	if not body.is_in_group("player"):
		return

	_start_fade(-80.0, fade_out_duration, true)


func _start_fade(to_db: float, duration: float, stop_after := false) -> void:
	# Annule le fade précédent si on entre/sort rapidement
	if _tween:
		_tween.kill()

	_tween = create_tween()
	_tween.tween_property(audio, "volume_db", to_db, duration)\
		.set_trans(Tween.TRANS_SINE)\
		.set_ease(Tween.EASE_IN_OUT)

	if stop_after:
		_tween.tween_callback(audio.stop)
