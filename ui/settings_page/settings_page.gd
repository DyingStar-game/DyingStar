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
	"%%MENU_CAT_DEBUG": preload("res://ui/settings_page/debug_page/debug_settings_page.tscn"),
}
const _TAB_FONT_SIZE : int = 18
## Every page's controls one step under the captions (which keep their LabelSettings).
const _PAGE_THEME : Theme = preload("res://ui/settings_page/settings_theme.tres")
## Under the host's TopBar, which stays over this page (its arrow is the way back).
const _GAP_UNDER_BAR_PX : float = 16.0
const _SOUNDS : PackedScene = preload("res://ui/InstallSounds.tscn")
## The see-through veil: this dark from the screen's left edge — dark enough that bright ground or a
## lit building behind the settings no longer shows through their text (0.82 let it)...
const VEIL_ALPHA : float = 0.93
## ...until this far short of the settings' right edge (their controls have their own dark box)...
const VEIL_FADE_IN_PX : float = 60.0
## ...then easing out to nothing this far past it: beyond, the scene keeps its true colours. Wide:
## at 240 px the edge of the veil read as a dark column standing over the scene.
const VEIL_FADE_OUT_PX : float = 560.0
## Stops drawing the ease (smoothstep) between those two points.
const _VEIL_STEPS : int = 24
## Texels across the veil's texture: one per screen pixel or so, so the ease shows no steps. At 256
## it did, stretched over a wide screen.
const _VEIL_TEXELS : int = 2048

## Set before adding the page: no opaque background, only a veil, so the scene shows through (the
## menu stage, or the game behind the pause menu).
## The pause menu keeps the default.
var see_through : bool = false
var tabs : TabStrip

@onready var settings_container : SubViewport = $Control/MarginContainer/VBoxContainer/Body/SubViewportContainer/SubViewport


func _ready() -> void:
	if see_through:
		var background : TextureRect = $Control/Background
		background.visible = false
		# Dark behind the settings only, fading out just past them: the page stays readable over bright
		# ground (a lit plain, snow), the scene beside it keeps its true colours. A flat veil over the
		# whole screen was one or the other.
		var veil := TextureRect.new()
		veil.name = "Veil"
		veil.stretch_mode = TextureRect.STRETCH_SCALE
		veil.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		veil.anchor_bottom = 1.0
		veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
		$Control.add_child(veil)
		$Control.move_child(veil, background.get_index())
		var page_area : Control = $Control/MarginContainer/VBoxContainer/Body/SubViewportContainer
		page_area.resized.connect(_fit_veil.bind(veil, page_area))
		# Once the layout is done too: an area already at its size never says it resized.
		_fit_veil.call_deferred(veil, page_area)
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
	# The tabs, and at the other end of their row the frame rate: on every tab, so what an option costs
	# shows wherever the option is, not only on the Graphics tab where it was the first line.
	var row := HBoxContainer.new()
	row.name = "TabRow"
	row.add_child(tabs)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(gap)
	var perf := PerfLabel.new()
	perf.name = "Perf"
	perf.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(perf)
	var column : VBoxContainer = $Control/MarginContainer/VBoxContainer
	column.add_child(row)
	column.move_child(row, 0)
	var rule := HSeparator.new()
	column.add_child(rule)
	column.move_child(rule, 1)
	var sounds : Node = _SOUNDS.instantiate()
	sounds.root_path = NodePath("../Control/MarginContainer/VBoxContainer/TabRow/Tabs")
	add_child(sounds)
	open("%%MENU_CAT_GENERAL")


## Show one category (its translation key, a CATEGORIES key).
func open(category_key: String) -> void:
	if tabs.active() == StringName(category_key):
		return
	for child in settings_container.get_children():
		child.queue_free()
	var page : Control = (CATEGORIES[category_key] as PackedScene).instantiate()
	page.theme = _PAGE_THEME
	# Over a scene the veil is the page's background: its own box would draw a hard edge over it.
	var box : CanvasItem = page.get_node_or_null("ColorRect")
	if box != null:
		box.visible = not see_through
	settings_container.add_child(page)
	tabs.set_active(StringName(category_key))
	category_changed.emit(category_key)


## The veil from the screen's left edge to just past the settings' right one.
func _fit_veil(veil: TextureRect, page_area: Control) -> void:
	var edge : float = page_area.get_global_rect().end.x
	var width : float = edge + VEIL_FADE_OUT_PX
	veil.offset_right = width
	veil.texture = veil_texture(maxf(edge - VEIL_FADE_IN_PX, 0.0) / width)


## Left to right: VEIL_ALPHA up to `solid_to` (a share of its width), then easing out to nothing.
static func veil_texture(solid_to: float) -> GradientTexture2D:
	var start : float = clampf(solid_to, 0.0, 1.0)
	var offsets := PackedFloat32Array([0.0])
	var colors := PackedColorArray([Color(0, 0, 0, VEIL_ALPHA)])
	for i in _VEIL_STEPS + 1:
		var t : float = float(i) / _VEIL_STEPS
		offsets.append(lerpf(start, 1.0, t))
		colors.append(Color(0, 0, 0, VEIL_ALPHA * (1.0 - smoothstep(0.0, 1.0, t))))
	var gradient := Gradient.new()
	gradient.offsets = offsets
	gradient.colors = colors
	var texture := GradientTexture2D.new()
	texture.width = _VEIL_TEXELS
	texture.height = 1
	texture.gradient = gradient
	texture.fill_from = Vector2(0.0, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	return texture
