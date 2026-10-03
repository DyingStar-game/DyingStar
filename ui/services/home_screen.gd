class_name ServiceHomeScreen
extends VBoxContainer

## The tablet's left rail: the brand bar (ARES mark, OS name, clock) over the app grid. Tiles emit
## [signal app_selected]; the tablet shows the matching app in the content pane on the right.

signal app_selected(id: String)

## The lore's manufacturer mark (a white wordmark on transparent, see the ARES decal assets). Cropped
## to its own bounds and tinted with the accent, so it reads as the tablet's brand at any size.
const ARES_LOGO := preload("res://assets/textures/decals/ares_logo/ares_logo_decal_alpha.png")
const ARES_LOGO_REGION := Rect2(51, 67, 416, 131)

var _clock: Label
var _tiles: Dictionary = {}  # id -> ServiceAppTile


func setup(apps: Array) -> void:
	add_theme_constant_override("separation", 16)
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	add_child(_system_bar())
	add_child(_section_label(tr("%%SVC_RAIL_APPLICATIONS")))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.add_child(_app_grid(apps))
	add_child(scroll)

	var timer := Timer.new()
	timer.wait_time = 1.0
	timer.autostart = true
	timer.timeout.connect(_tick_clock)
	add_child(timer)
	_tick_clock()


## Mark the tile of the app currently open (or clear every mark with `""`).
func set_active(id: String) -> void:
	for key: String in _tiles:
		ServiceStyle.apply_tile(_tiles[key], key == id)


func _system_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 12)
	bar.add_child(_brand_logo())

	var title := Label.new()
	title.text = "A.R.E.S OS"
	title.add_theme_color_override("font_color", ServiceStyle.TEXT)
	ServiceStyle.font_of(title, 20, true)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	_clock = Label.new()
	_clock.add_theme_color_override("font_color", ServiceStyle.TEXT)
	ServiceStyle.font_of(_clock, 20, true)
	_clock.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar.add_child(_clock)
	return bar


## The ARES wordmark, cropped to the mark inside the decal texture and tinted with the accent.
func _brand_logo() -> Control:
	var atlas := AtlasTexture.new()
	atlas.atlas = ARES_LOGO
	atlas.region = ARES_LOGO_REGION
	var logo := TextureRect.new()
	logo.texture = atlas
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.modulate = ServiceStyle.ACCENT
	logo.custom_minimum_size = Vector2(72, 26)
	logo.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return logo


func _section_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", ServiceStyle.MUTED)
	ServiceStyle.font_of(label, 13, true)
	var rule := StyleBoxFlat.new()
	rule.bg_color = Color.TRANSPARENT
	rule.border_width_bottom = 1
	rule.border_color = ServiceStyle.BORDER_STRONG
	rule.content_margin_bottom = 4.0
	label.add_theme_stylebox_override("normal", rule)
	return label


func _app_grid(apps: Array) -> Control:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	for app: Dictionary in apps:
		var id: String = str(app["id"])
		var tile := ServiceAppTile.new()
		tile.setup(id, tr(str(app["title"])), app["icon"])
		tile.pressed.connect(func() -> void: app_selected.emit(id))
		grid.add_child(tile)
		_tiles[id] = tile
	return grid


func _tick_clock() -> void:
	var now := Time.get_time_dict_from_system()
	_clock.text = "%02d:%02d" % [int(now["hour"]), int(now["minute"])]
