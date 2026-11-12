class_name ScreenHum
extends AudioStreamPlayer3D

## The fan hum of a screen of the world: a machine's console, a wall screen, a town hall's giant board. Every
## screen has one but the vehicles' (a cab has its own sounds) and the one a player wears on the wrist.
## CLIENT only.
##
## A looped sound heard from a few metres: it plays only while the camera is within HEAR_M (looked at
## every CHECK_S), from a random point of the loop so that two screens side by side do not beat together.

const STREAM: AudioStream = preload("res://assets/_universe/audio/sfx/ui/screen-fan-hum.ogg")
const NODE_NAME := &"ScreenHum"
## From how far (m) the hum of a small screen is heard; it plays only within. A big screen is heard from
## further, by half its size (reach_for): its middle hangs metres away from who stands under it.
const HEAR_M := 7.0
## The distance (m) at which a small screen's hum is at its level; a big one's grows with it (unit_for).
const UNIT_M := 1.5
## Its level (dB) a metre away: a room's background, under a voice.
const VOLUME_DB := -17.0
## How often (s) the distance to the camera is looked at.
const CHECK_S := 0.5

## The screen's largest side (m): 0 for a console.
var size_m: float = 0.0

var _check_left: float = randf() * CHECK_S


## Give [param screen] its hum, at [param at] in its frame; [param screen_size_m] is the largest side of
## a big screen (a wall screen, a giant board). Null where there is none: on the dedicated server, in the
## editor, on a vehicle's screen or a player's (hums_on), or when it already has one.
static func attach(screen: Node3D, at: Vector3 = Vector3.ZERO, screen_size_m: float = 0.0) -> ScreenHum:
	if screen == null or Engine.is_editor_hint() or GameOrchestrator.is_server() or not hums_on(screen) \
			or screen.has_node(NodePath(NODE_NAME)):
		return null
	var hum := ScreenHum.new()
	hum.name = NODE_NAME
	hum.position = at
	hum.size_m = maxf(screen_size_m, 0.0)
	screen.add_child(hum)
	return hum


## From how far (m) the hum of a screen [param screen_size_m] across is heard. Pure.
static func reach_for(screen_size_m: float) -> float:
	return HEAR_M + maxf(screen_size_m, 0.0) * 0.5


## The distance (m) at which the hum of a screen [param screen_size_m] across is at its level. Pure.
static func unit_for(screen_size_m: float) -> float:
	return UNIT_M + maxf(screen_size_m, 0.0) * 0.25


## Whether a screen at [param node] hums: not one carried by a vehicle or worn by a player.
static func hums_on(node: Node) -> bool:
	var n: Node = node
	while n != null:
		if n is Vehicle or n is Player or n.is_in_group("vehicle"):
			return false
		n = n.get_parent()
	return true


## Whether a listener [param distance] m away hears a screen [param screen_size_m] across. Pure.
static func heard_from(distance: float, screen_size_m: float = 0.0) -> bool:
	return distance <= reach_for(screen_size_m)


func _ready() -> void:
	stream = STREAM
	bus = Sfx3D.SFX_BUS
	volume_db = VOLUME_DB
	max_db = VOLUME_DB  # never louder than its level, however close the ear (the default tops at +3 dB)
	unit_size = unit_for(size_m)
	max_distance = reach_for(size_m)
	attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE


func _process(delta: float) -> void:
	_check_left -= delta
	if _check_left > 0.0:
		return
	_check_left = CHECK_S
	var camera := get_viewport().get_camera_3d()
	var near: bool = camera != null and heard_from(camera.global_position.distance_to(global_position), size_m)
	if near and not playing:
		play(randf() * stream.get_length())
	elif not near and playing:
		stop()
