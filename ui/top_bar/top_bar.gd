class_name TopBar
extends CanvasLayer
## The menu bar across the top of the screen, as in SQUAD: the logo on the left, the entries on the
## right (a TabStrip), and "‹ Back" before them while a sub-screen is open. The home screen and
## the pause menu each own one; the settings page opens UNDER it (TopBar.LAYER is above it), so the
## bar stays — its entry marked active, its arrow closing the settings.
##
## The strip spans the whole width; its content keeps to the centred 16:9 area (SafeArea).

signal entry_pressed(key: StringName)
signal back_pressed

## Above the settings page (5) and the in-game panels (4).
const LAYER : int = 6
const HEIGHT_PX : float = 96.0
const LOGO : Texture2D = preload("res://ui/main_page/dyingstar-logo.png")
const _LOGO_HEIGHT_PX : float = 48.0
const _SIDE_PX : float = 48.0
const _FONT_SIZE : int = 22
const _SOUNDS : PackedScene = preload("res://ui/InstallSounds.tscn")

var tabs : TabStrip
var _back : TabStrip
var _area : Control


func _init() -> void:
	layer = LAYER
	var strip := Panel.new()
	strip.name = "Strip"
	strip.anchor_right = 1.0
	strip.offset_bottom = HEIGHT_PX
	strip.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.1, 0.78)
	style.border_width_bottom = 1
	style.border_color = Color(1.0, 1.0, 1.0, 0.25)
	strip.add_theme_stylebox_override("panel", style)
	add_child(strip)
	# Full-screen and click-through: only here so SafeArea can narrow it on a wide screen.
	_area = Control.new()
	_area.name = "Area"
	_area.set_anchors_preset(Control.PRESET_FULL_RECT)
	_area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_area)
	var row := HBoxContainer.new()
	row.name = "Row"
	row.anchor_right = 1.0
	row.offset_left = _SIDE_PX
	row.offset_right = -_SIDE_PX
	row.offset_bottom = HEIGHT_PX
	row.add_theme_constant_override("separation", 36)
	_area.add_child(row)
	var logo := TextureRect.new()
	logo.texture = LOGO
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.custom_minimum_size = Vector2(_LOGO_HEIGHT_PX * LOGO.get_width() / LOGO.get_height(), _LOGO_HEIGHT_PX)
	logo.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(logo)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)
	# "‹ BACK" in the entries' own style: a strip of one, so it translates and looks like them.
	_back = TabStrip.new(_FONT_SIZE)
	_back.name = "Back"
	_back.add_entry(&"back", "%%RETURN", "‹  ")
	_back.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_back.visible = false
	_back.selected.connect(func(_key: StringName) -> void: back_pressed.emit())
	row.add_child(_back)
	tabs = TabStrip.new(_FONT_SIZE)
	tabs.name = "Tabs"
	tabs.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tabs.selected.connect(entry_pressed.emit)
	row.add_child(tabs)
	var sounds : Node = _SOUNDS.instantiate()
	sounds.root_path = NodePath("../Area/Row/Tabs")
	add_child(sounds)


func _ready() -> void:
	SafeArea.keep(_area)


func add_entry(key: StringName, label_key: String) -> Button:
	return tabs.add_entry(key, label_key)


func set_active(key: StringName) -> void:
	tabs.set_active(key)


func set_back_visible(on: bool) -> void:
	_back.visible = on
