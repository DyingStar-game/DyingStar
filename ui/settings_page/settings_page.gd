extends CanvasLayer

## The category on show changed (its translation key, e.g. the graphics one) — the main menu stage
## glides to match it.
signal category_changed(key: String)

## The categories, as tabs across the top: translation key -> page. The key is also what
## category_changed carries (MainPage.SCREEN_OF_CATEGORY).
const CATEGORIES : Dictionary = {
	"%%MENU_CAT_GENERAL": preload("res://ui/settings_page/general_page/general_settings_page.tscn"),
	"%%MENU_CAT_GRAPHICS": preload("res://ui/settings_page/graphical_page/graphical_settings_page.tscn"),
	"%%MENU_CAT_AUDIO": preload("res://ui/settings_page/audio_page/audio_settings_page.tscn"),
	"%%MENU_CAT_CONTROLS": preload("res://ui/settings_page/control_page/control_settings_page.tscn"),
}
const _TAB_FONT_SIZE : int = 18
## Under the host's TopBar, which stays over this page (its arrow is the way back).
const _GAP_UNDER_BAR_PX : float = 16.0
const _SOUNDS : PackedScene = preload("res://ui/InstallSounds.tscn")

## Set before adding the page: no opaque background, only a veil, so the menu stage shows through.
## The pause menu keeps the default.
var see_through : bool = false
var tabs : TabStrip

@onready var settings_container : SubViewport = $Control/MarginContainer/VBoxContainer/SubViewportContainer/SubViewport


func _ready() -> void:
	if see_through:
		var background : TextureRect = $Control/Background
		background.visible = false
		var veil := ColorRect.new()
		veil.color = Color(0.0, 0.0, 0.0, 0.35)
		veil.set_anchors_preset(Control.PRESET_FULL_RECT)
		veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
		$Control.add_child(veil)
		$Control.move_child(veil, background.get_index())
	var margin : MarginContainer = $Control/MarginContainer
	margin.add_theme_constant_override("margin_top", int(TopBar.HEIGHT_PX + _GAP_UNDER_BAR_PX))
	# The content in a centred 16:9 area on a wide screen; the background keeps the whole screen.
	SafeArea.keep(margin)
	tabs = TabStrip.new(_TAB_FONT_SIZE)
	tabs.name = "Tabs"
	tabs.alignment = BoxContainer.ALIGNMENT_BEGIN
	for key: String in CATEGORIES:
		tabs.add_entry(StringName(key), key)
	tabs.selected.connect(func(key: StringName) -> void: open(String(key)))
	var column : VBoxContainer = $Control/MarginContainer/VBoxContainer
	column.add_child(tabs)
	column.move_child(tabs, 0)
	var rule := HSeparator.new()
	column.add_child(rule)
	column.move_child(rule, 1)
	var sounds : Node = _SOUNDS.instantiate()
	sounds.root_path = NodePath("../Control/MarginContainer/VBoxContainer/Tabs")
	add_child(sounds)
	open("%%MENU_CAT_GENERAL")


## Show one category (its translation key, a CATEGORIES key).
func open(category_key: String) -> void:
	if tabs.active() == StringName(category_key):
		return
	for child in settings_container.get_children():
		child.queue_free()
	settings_container.add_child((CATEGORIES[category_key] as PackedScene).instantiate())
	tabs.set_active(StringName(category_key))
	category_changed.emit(category_key)
