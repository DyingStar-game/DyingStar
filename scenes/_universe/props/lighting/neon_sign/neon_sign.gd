@tool
class_name NeonSign
extends Node3D

## A neon sign on a facade: the text as a thin extruded tube with an emissive material (bright enough
## for the environment's glow to bloom, like the LED panels), plus a small shadowless light that tints
## the wall around it. The text is a translation key of localisation.csv: it is translated
## here and again whenever the language changes. A Label3D cannot do this: its colour cannot go above
## 1, so it never blooms.
##
## Pure decoration: the dedicated server drops it. Its light casts no shadow, so LampShadowBudget
## leaves it alone and it never takes a place in the shadow atlas.
##
## The tube and the light are INTERNAL children built here: they are never saved into the scene that
## places the sign, so the editor preview leaves no generated mesh behind, and two signs never share
## one text. Drop a NeonSign node on a facade; its +Z is the side the text is read from.

## Translation key of the text (localisation.csv), e.g. %%SIGN_GARAGE. A plain word is shown as is.
## No default: Godot does not save a value equal to the default, so a scene would silently hold none.
@export var text_key: String = "":
	set(value):
		text_key = value
		_apply()
## Colour of the tube. The light takes the same colour.
@export var color: Color = Color(1.0, 0.729, 0.031):
	set(value):
		color = value
		_apply()
## How bright the tube is (emission energy). Above roughly 1 the environment's glow makes it bloom;
## 2 to 2.5 reads as neon in game (tuned on the village signs), far below the LED panels' 25.
@export_range(0.0, 64.0, 0.5) var glow: float = 2.5:
	set(value):
		glow = value
		_apply()
## Height of a capital letter, in metres.
@export_range(0.05, 5.0, 0.01) var letter_height: float = 0.5:
	set(value):
		letter_height = value
		_apply()
## Thickness of the tube (how far the letters stand off the wall), in metres.
@export_range(0.0, 0.5, 0.005) var depth: float = 0.04:
	set(value):
		depth = value
		_apply()
## Font of the letters.
@export var font: Font = preload("res://assets/fonts/Xolonium/Xolonium-Regular.ttf"):
	set(value):
		font = value
		_apply()
@export_group("Light")
## Energy of the light that tints the facade. 0 switches it off and keeps only the glow.
@export_range(0.0, 16.0, 0.05) var light_energy: float = 1.5:
	set(value):
		light_energy = value
		_apply()
## Reach of that light, in metres.
@export_range(0.5, 40.0, 0.5) var light_range: float = 5.0:
	set(value):
		light_range = value
		_apply()
## How fast the light fades with distance (OmniLight3D.omni_attenuation): brightness goes as
## 1 / distance^attenuation inside light_range, then is forced to zero over its last third. At 1 it
## barely fades and that forced cut draws a hard round edge on the ground; at 2 (the physical inverse
## square) it has already faded when the range ends, and the patch melts away. Raise light_energy
## and light_range with it.
@export_range(0.0, 4.0, 0.05) var light_attenuation: float = 1.0:
	set(value):
		light_attenuation = value
		_apply()
## How far in front of the letters the light sits, in metres (it lights the wall from there).
@export_range(0.0, 5.0, 0.05) var light_offset: float = 0.5:
	set(value):
		light_offset = value
		_apply()
@export_group("Distance")
## Beyond this distance from the camera the sign is not drawn and its light fades out, in metres.
@export_range(10.0, 2000.0, 10.0) var fade_distance: float = 300.0:
	set(value):
		fade_distance = value
		_apply()

## Font size the glyph outlines are built at; the world size comes from letter_height.
const FONT_SIZE := 64
## Height of a capital letter as a fraction of the font size (Xolonium's cap height).
const CAP_HEIGHT := 0.72
## A neon tube does not come on clean: the gas strikes a few times first. [lit?, seconds] steps,
## each stretched or shortened a little at random, then the tube holds.
const IGNITION: Array = [[true, 0.05], [false, 0.12], [true, 0.04], [false, 0.25], [true, 0.08], [false, 0.06]]

## Whether the sign is switched on. A sign stays lit unless a Photocell switches it (set_lit).
var lit: bool = true

var _tube: MeshInstance3D
var _light: OmniLight3D
## What the tube shows right now: differs from `lit` while it strikes.
var _glowing: bool = true
var _ignition: Tween


func _ready() -> void:
	if not Engine.is_editor_hint() and OS.has_feature("dedicated_server"):
		queue_free()  # nothing to see on a headless server
		return
	_tube = MeshInstance3D.new()
	_tube.name = "Tube"
	_tube.mesh = TextMesh.new()
	_tube.material_override = StandardMaterial3D.new()
	_tube.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_tube, false, INTERNAL_MODE_BACK)
	_light = OmniLight3D.new()
	_light.name = "Glow"
	_light.shadow_enabled = false
	_light.distance_fade_enabled = true
	add_child(_light, false, INTERNAL_MODE_BACK)
	_apply()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_apply()


## Switch the sign on or off. Coming on, the tube strikes a few times before it holds (IGNITION),
## unless [param animate] is false (a sign found lit when the player arrives does not flicker).
func set_lit(on: bool, animate: bool = true) -> void:
	if _ignition != null:
		_ignition.kill()
		_ignition = null
	lit = on
	if on and animate and is_inside_tree():
		_ignition = create_tween()
		for step: Array in IGNITION:
			_ignition.tween_callback(_show.bind(step[0]))
			_ignition.tween_interval(step[1] * randf_range(0.6, 1.4))
		_ignition.tween_callback(_show.bind(true))
	else:
		_show(on)


## True while the tube strikes after being switched on.
func is_igniting() -> bool:
	return _ignition != null and _ignition.is_running()


func _show(on: bool) -> void:
	_glowing = on
	_apply()


## The text as shown: the translation of text_key. In the editor the project's translations may not
## be loaded; the key then shows without its %% prefix rather than as a raw key.
func shown_text() -> String:
	var shown := tr(text_key)
	if shown == text_key and text_key.begins_with("%%"):
		shown = text_key.trim_prefix("%%")
	return shown


func _apply() -> void:
	if not is_node_ready() or _tube == null:
		return
	var mesh := _tube.mesh as TextMesh
	mesh.text = shown_text()
	mesh.font = font
	mesh.font_size = FONT_SIZE
	mesh.pixel_size = letter_height / (FONT_SIZE * CAP_HEIGHT)
	mesh.depth = depth
	var tube := _tube.material_override as StandardMaterial3D
	# Switched off (by day), the tube keeps its colour: painted glass, without glow or light. Darkened, it
	# read as a black word on the facade.
	tube.albedo_color = color
	tube.emission_enabled = _glowing
	tube.emission = color
	tube.emission_energy_multiplier = glow
	_tube.visibility_range_end = fade_distance
	_light.light_color = color
	_light.light_energy = light_energy
	_light.visible = _glowing and light_energy > 0.0
	_light.omni_range = light_range
	_light.omni_attenuation = light_attenuation
	_light.position = Vector3(0.0, 0.0, light_offset)
	_light.distance_fade_begin = maxf(0.0, fade_distance - 20.0)
	_light.distance_fade_length = 20.0
