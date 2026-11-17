@tool
extends VBoxContainer

## The asset library: a tab of the editor's bottom panel that lists the project's models, scenes,
## materials, textures, sounds and shaders by kind, whatever folder they are in.
##
## Three columns: the categories with how many assets each holds, a grid of thumbnails filtered by tag
## and by search, and the selected asset with the one action that fits its kind. Nothing to configure:
## the kind is the resource's own class and the tags come from its folders (asset_catalog.gd).
##
## The thumbnails are the editor's own (EditorResourcePreview), except those of models and scenes,
## drawn by asset_thumbnailer.gd so that they all look alike. Dragging from the grid hands over what the FileSystem dock does, so the
## 3D view instances a dropped model by itself (asset_grid.gd).

const Catalog := preload("res://addons/dyingstar/asset_library/asset_catalog.gd")
const Grid := preload("res://addons/dyingstar/asset_library/asset_grid.gd")
const Stage := preload("res://addons/dyingstar/asset_library/asset_stage.gd")
const Thumbnailer := preload("res://addons/dyingstar/asset_library/asset_thumbnailer.gd")

## Height of the panel, in pixels at 100 % editor scale: enough for three rows of thumbnails.
const PANEL_HEIGHT := 300
## Width and height of a thumbnail in the grid, in pixels at 100 % editor scale: as the library opens
## the first time, then the smallest and largest the zoom goes to, and its step.
const THUMBNAIL_SIZE := 64
const MIN_THUMBNAIL_SIZE := 40
const MAX_THUMBNAIL_SIZE := 200
const THUMBNAIL_STEP := 8
## How much wider than its thumbnail a grid cell is, in pixels at 100 % editor scale: room for the name.
const NAME_MARGIN := 36
## Where the chosen zoom is kept between sessions (this project's editor metadata, never committed).
const SETTINGS_SECTION := "dyingstar"
const ZOOM_SETTING := "asset_library_thumbnail_size"
## Widths of the category and detail columns, in pixels at 100 % editor scale.
const CATEGORY_WIDTH := 190
const DETAIL_WIDTH := 240
## Height of the preview in the detail column, in pixels at 100 % editor scale.
const PREVIEW_HEIGHT := 150
## Width of the tag field, in pixels at 100 % editor scale.
const TAG_FIELD_WIDTH := 130
## Width and height, in pixels, of the picture a credit mark is drawn on. The grid scales it to the
## zoom in use, so it is made large enough to stay sharp at the largest.
const BADGE_CANVAS := 256
## Width of the credit mark, as a share of its thumbnail's.
const BADGE_SHARE := 0.26
## Width of the category's icon on a thumbnail listed under "All", as a share of the thumbnail's.
const KIND_SHARE := 0.16
## The word "LOD", one string a row, "#" a lit cell: the mark of an asset with several levels of detail.
const LOD_LETTERS: PackedStringArray = [
	"#.....##..###.",
	"#....#..#.#..#",
	"#....#..#.#..#",
	"#....#..#.#..#",
	"#....#..#.#..#",
	"#....#..#.#..#",
	"####..##..###.",
]
## Empty cells around the word, and how many cells the thumbnail is wide: the size of the mark.
const LOD_PADDING := 2
const LOD_CELLS_ACROSS := 64
## A small picture (the icon of a kind) is enlarged at most this many times on the canvas.
const MAX_ICON_ENLARGEMENT := 6.0
## Thumbnails asked of the editor per frame: all at once would stall it on a long list.
const PREVIEWS_PER_FRAME := 16
## Seconds waited after the project's files change before listing them again: a save changes many.
const RESCAN_DELAY := 0.5
## Orbit of the 3D preview: radians turned per pixel dragged, and zoom step per wheel notch.
const ORBIT_SPEED := 0.01
const ZOOM_STEP := 0.9
## Written over the 3D preview of the selected model.
const STAGE_HINT := "Drag: turn  |  Right-drag: move  |  Wheel: zoom"
## Shown under the grid when there is nothing else to say.
const HINT := "Drag into the 3D view to instance. Double-click to open or play."

var _entries: Array = []
var _shown: Array = []
var _category: StringName = Catalog.ALL
var _tag := ""
var _selected: Dictionary = {}
## What the detail column shows: the selected asset, or one of its levels of detail.
var _viewed: Dictionary = {}
## Bumped each time the grid is rebuilt: a thumbnail that arrives for an older list is dropped.
var _generation := 0
## Whether the project's files changed since they were last listed.
var _stale := true
## Grid indices whose thumbnail is still to be asked for.
var _pending: Array[int] = []
## folder -> its file names, read once per scan.
var _folder_files: Dictionary = {}
## The credit marks as images: {editor icon name: Image}.
var _badges: Dictionary = {}
## The "LOD" mark, made on first use.
var _lod_plate: Image = null

var _search: LineEdit
var _auto_play: Button
var _uncredited: Button
var _zoom: HSlider
var _categories: ItemList
var _tag_field: LineEdit
var _tag_strip: ScrollContainer
var _tags: HBoxContainer
var _more_tags: MenuButton
var _grid: Grid
var _status: Label
var _detail: VBoxContainer
var _empty: Label
var _picture: TextureRect
var _stage_box: SubViewportContainer
var _stage: Stage
var _sound_row: HBoxContainer
var _lod_row: HFlowContainer
var _play: Button
var _name: Label
var _info: Label
var _action: Button
var _locate: Button
var _player: AudioStreamPlayer
var _thumbnailer: Thumbnailer
var _rescan: Timer


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	custom_minimum_size.y = PANEL_HEIGHT * _scale()
	_build()
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(_on_files_changed)
	visibility_changed.connect(_on_visibility_changed)
	_on_visibility_changed()


func _process(_delta: float) -> void:
	if _pending.is_empty():
		set_process(false)
		return
	if not is_visible_in_tree():
		return
	var previewer := EditorInterface.get_resource_previewer()
	for i in mini(PREVIEWS_PER_FRAME, _pending.size()):
		var index: int = _pending.pop_front()
		var entry: Dictionary = _shown[index]
		var request := [_generation, index]
		# A model or a scene is drawn on our own stage, framed and lit the same for all: the editor has
		# no thumbnail for a model, and its thumbnail of a scene is whatever its viewport showed at the
		# last save.
		if entry["category"] in [Catalog.MODEL, Catalog.SCENE]:
			_thumbnailer.request(entry["path"], _on_stage_thumbnail.bind(request))
		else:
			previewer.queue_resource_preview(entry["path"], self, &"_on_preview", request)


# --- Layout ----------------------------------------------------------------------------------------


func _build() -> void:
	_player = AudioStreamPlayer.new()
	_player.finished.connect(_refresh_play_button)
	add_child(_player)
	_thumbnailer = Thumbnailer.new()
	add_child(_thumbnailer)
	_rescan = Timer.new()
	_rescan.one_shot = true
	_rescan.wait_time = RESCAN_DELAY
	_rescan.timeout.connect(_scan)
	add_child(_rescan)

	add_child(_build_bar())
	var columns := HSplitContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(columns)
	_categories = ItemList.new()
	_categories.custom_minimum_size.x = CATEGORY_WIDTH * _scale()
	_categories.item_selected.connect(_on_category_selected)
	columns.add_child(_categories)
	var right := HSplitContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(right)
	right.add_child(_build_centre())
	right.add_child(_build_detail())


func _build_bar() -> Control:
	var bar := HBoxContainer.new()
	_search = LineEdit.new()
	_search.placeholder_text = "Search (name, tag, path)"
	_search.clear_button_enabled = true
	_search.right_icon = _icon(&"Search")
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(_on_search_changed)
	bar.add_child(_search)
	_zoom = HSlider.new()
	_zoom.min_value = MIN_THUMBNAIL_SIZE
	_zoom.max_value = MAX_THUMBNAIL_SIZE
	_zoom.step = THUMBNAIL_STEP
	_zoom.value = float(EditorInterface.get_editor_settings().get_project_metadata(
			SETTINGS_SECTION, ZOOM_SETTING, THUMBNAIL_SIZE))
	_zoom.custom_minimum_size.x = 90 * _scale()
	_zoom.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_zoom.tooltip_text = "Thumbnail size (also Ctrl + wheel over the grid)."
	_zoom.value_changed.connect(_on_zoom_changed)
	bar.add_child(_zoom)
	_auto_play = Button.new()
	_auto_play.text = "Auto-play"
	_auto_play.icon = _icon(&"AudioStreamPlayer")
	_auto_play.toggle_mode = true
	_auto_play.tooltip_text = "Play a sound as soon as it is selected."
	bar.add_child(_auto_play)
	_uncredited = Button.new()
	_uncredited.text = "No credit"
	_uncredited.icon = _icon(&"StatusError")
	_uncredited.toggle_mode = true
	_uncredited.tooltip_text = ("Show only the sounds, models and textures that have no credit file yet.\n"
			+ "A green tick marks an asset with its credit, a red cross one without.")
	_uncredited.toggled.connect(_on_uncredited_toggled)
	bar.add_child(_uncredited)
	var refresh := Button.new()
	refresh.icon = _icon(&"Reload")
	refresh.tooltip_text = "List the project's assets again."
	refresh.pressed.connect(_scan.bind(true))
	bar.add_child(refresh)
	return bar


func _build_centre() -> Control:
	var centre := VBoxContainer.new()
	centre.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	centre.add_child(_build_tag_row())
	_grid = Grid.new()
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid.max_columns = 0
	_grid.same_column_width = true
	_grid.icon_mode = ItemList.ICON_MODE_TOP
	_apply_zoom(_zoom.value)
	_grid.gui_input.connect(_on_grid_input)
	_grid.max_text_lines = 2
	_grid.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_grid.select_mode = ItemList.SELECT_MULTI
	_grid.multi_selected.connect(_on_grid_selected)
	_grid.item_activated.connect(_on_grid_activated)
	centre.add_child(_grid)
	_status = Label.new()
	_status.text = HINT
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status.modulate.a = 0.7
	centre.add_child(_status)
	return centre


## The tags on one line, in alphabetical order, after a field that narrows them to what is typed in it
## (Enter takes the first); those that do not fit are behind the "..." button.
func _build_tag_row() -> Control:
	var row := HBoxContainer.new()
	_tag_field = LineEdit.new()
	_tag_field.placeholder_text = "Tag..."
	_tag_field.clear_button_enabled = true
	_tag_field.custom_minimum_size.x = TAG_FIELD_WIDTH * _scale()
	_tag_field.tooltip_text = "Type to find a tag, Enter to take the first one."
	_tag_field.text_changed.connect(_on_tag_typed)
	_tag_field.text_submitted.connect(_on_tag_submitted)
	row.add_child(_tag_field)
	# A scroll container asks for no more width than it is given, however many tags it holds: a plain
	# row would push the whole column as wide as all of them.
	_tag_strip = ScrollContainer.new()
	_tag_strip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tag_strip.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_tag_strip.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tag_strip.resized.connect(_fit_tags)
	_tags = HBoxContainer.new()
	_tag_strip.add_child(_tags)
	row.add_child(_tag_strip)
	_more_tags = MenuButton.new()
	_more_tags.text = "..."
	_more_tags.flat = false
	_more_tags.tooltip_text = "The other tags."
	_more_tags.get_popup().index_pressed.connect(_on_more_tag_pressed)
	row.add_child(_more_tags)
	return row


## Written over the 3D preview, in its corner: that it can be handled, and how.
func _build_stage_hint() -> Control:
	var hint := Label.new()
	hint.text = STAGE_HINT
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.add_theme_font_size_override(&"font_size", int(11 * _scale()))
	hint.add_theme_color_override(&"font_color", Color(1, 1, 1, 0.75))
	hint.add_theme_color_override(&"font_shadow_color", Color(0, 0, 0, 0.8))
	# Held by the bottom right corner and growing away from it, whatever the preview's size.
	hint.anchor_left = 1.0
	hint.anchor_top = 1.0
	hint.anchor_right = 1.0
	hint.anchor_bottom = 1.0
	hint.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	hint.offset_right = -6 * _scale()
	hint.offset_bottom = -3 * _scale()
	return hint


func _build_detail() -> Control:
	_detail = VBoxContainer.new()
	_detail.custom_minimum_size.x = DETAIL_WIDTH * _scale()
	_empty = Label.new()
	_empty.text = "Select an asset"
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty.modulate.a = 0.7
	_detail.add_child(_empty)

	_picture = TextureRect.new()
	_picture.custom_minimum_size.y = PREVIEW_HEIGHT * _scale()
	_picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_detail.add_child(_picture)
	_stage_box = SubViewportContainer.new()
	_stage_box.custom_minimum_size.y = PREVIEW_HEIGHT * _scale()
	_stage_box.stretch = true
	_stage_box.mouse_default_cursor_shape = Control.CURSOR_DRAG
	_stage_box.gui_input.connect(_on_stage_input)
	_stage = Stage.new()
	_stage.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	_stage_box.add_child(_stage)
	_stage_box.add_child(_build_stage_hint())
	_detail.add_child(_stage_box)

	_sound_row = HBoxContainer.new()
	_play = Button.new()
	_play.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_play.pressed.connect(_toggle_sound)
	_sound_row.add_child(_play)
	var volume := HSlider.new()
	volume.min_value = 0.0
	volume.max_value = 1.0
	volume.step = 0.01
	volume.value = 0.7
	volume.custom_minimum_size.x = 80 * _scale()
	volume.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	volume.tooltip_text = "Preview volume."
	volume.value_changed.connect(_on_volume_changed)
	_sound_row.add_child(volume)
	_on_volume_changed(volume.value)
	_detail.add_child(_sound_row)

	_lod_row = HFlowContainer.new()
	_detail.add_child(_lod_row)

	_name = Label.new()
	_name.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_detail.add_child(_name)
	_info = Label.new()
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info.modulate.a = 0.7
	_detail.add_child(_info)
	_action = Button.new()
	_action.pressed.connect(_run_action)
	_detail.add_child(_action)
	_locate = Button.new()
	_locate.text = "Show in FileSystem"
	_locate.pressed.connect(_show_in_file_system)
	_detail.add_child(_locate)
	_refresh_detail()
	return _detail


# --- The list --------------------------------------------------------------------------------------


## Read the project's assets from the editor's own file index: no file is opened to know its kind.
func _scan(forced: bool = false) -> void:
	var file_system := EditorInterface.get_resource_filesystem()
	# The editor's index is not complete while it reads the project: come back once it is.
	if file_system.is_scanning():
		_rescan.start()
		return
	_stale = false
	var found: Array = []
	_folder_files.clear()
	for root in Catalog.ROOTS:
		var folder := file_system.get_filesystem_path(root)
		if folder != null:
			_scan_folder(folder, found)
	found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["name"]).naturalnocasecmp_to(String(b["name"])) < 0)
	found = Catalog.group_lods(found)
	# The editor reports a change on every save: only rebuild when the list really differs.
	if not forced and _signature(found) == _signature(_entries) and not _entries.is_empty():
		return
	_entries = found
	_refresh_categories()
	_refresh_tags()
	_refresh_grid()


func _scan_folder(folder: EditorFileSystemDirectory, found: Array) -> void:
	for i in folder.get_file_count():
		var entry := Catalog.make_entry(folder.get_file_path(i), folder.get_file_type(i))
		if entry.is_empty():
			continue
		if entry["needs_credit"]:
			entry["credit"] = Catalog.credit_source(entry["path"], _files_in)
		found.append(entry)
	for i in folder.get_subdir_count():
		_scan_folder(folder.get_subdir(i), found)


## The file names of a folder, credit files included (the editor's index leaves text files out). Read
## once per scan.
func _files_in(folder: String) -> PackedStringArray:
	if not _folder_files.has(folder):
		_folder_files[folder] = DirAccess.get_files_at(folder)
	return _folder_files[folder]


## What the grid shows of each asset: when it is the same as before, the grid is left as it is.
func _signature(entries: Array) -> PackedStringArray:
	var lines := PackedStringArray()
	for entry: Dictionary in entries:
		lines.append("%s|%s" % [entry["path"], entry["credit"]])
	return lines


func _refresh_categories() -> void:
	var counts := Catalog.counts(_entries)
	_categories.clear()
	for category: Array in Catalog.CATEGORIES:
		var index := _categories.add_item("%s  (%d)" % [category[1], int(counts.get(category[0], 0))], _icon(category[2]))
		_categories.set_item_metadata(index, category[0])
		if category[0] == _category:
			_categories.select(index)


func _refresh_tags() -> void:
	for child in _tags.get_children():
		_tags.remove_child(child)
		child.queue_free()
	var tags := Catalog.tag_counts(_entries, _category)
	if _tag != "" and not tags.any(func(pair: Array) -> bool: return pair[0] == _tag):
		_tag = ""
	# The tag in use first, so it never ends up behind "...".
	tags = Catalog.matching_tags(tags, _tag_field.text, _tag)
	for pair: Array in tags:
		var button := Button.new()
		button.text = pair[0]
		button.toggle_mode = true
		button.button_pressed = pair[0] == _tag
		button.tooltip_text = "%d assets" % pair[1]
		button.pressed.connect(_on_tag_pressed.bind(String(pair[0])))
		_tags.add_child(button)
	_fit_tags.call_deferred()


## Show the tags that fit on the line; the others go into the "..." menu.
func _fit_tags() -> void:
	var menu := _more_tags.get_popup()
	menu.clear()
	var room := _tag_strip.size.x
	var used := 0.0
	var gap := float(_tags.get_theme_constant(&"separation"))
	var full := false
	for button: Button in _tags.get_children():
		var width := button.get_combined_minimum_size().x
		full = full or used + width > room
		button.visible = not full
		if full:
			menu.add_item("%s  (%s)" % [button.text, button.tooltip_text])
			menu.set_item_metadata(menu.item_count - 1, button.text)
		used += width + gap
	_more_tags.visible = menu.item_count > 0


func _on_tag_typed(_text: String) -> void:
	_refresh_tags()


## Enter in the tag field: take the first tag offered that is not already the one in use.
func _on_tag_submitted(_text: String) -> void:
	for button: Button in _tags.get_children():
		if button.text != _tag:
			_tag_field.text = ""
			_on_tag_pressed(button.text)
			return


func _on_more_tag_pressed(index: int) -> void:
	_on_tag_pressed(str(_more_tags.get_popup().get_item_metadata(index)))


func _refresh_grid() -> void:
	var selected_path := str(_selected.get("path", ""))
	_generation += 1
	_thumbnailer.cancel_pending()
	_shown = Catalog.filter(_entries, _category, _tag, _search.text, _uncredited.button_pressed)
	_grid.clear()
	_pending.clear()
	_selected = {}
	_viewed = {}
	for entry: Dictionary in _shown:
		var index := _grid.add_item(entry["name"], _badged(_type_icon(entry), entry))
		_grid.set_item_metadata(index, entry["path"])
		_grid.set_item_tooltip(index, "%s\n%s\n%s" % [
				entry["path"], ", ".join(entry["tags"] as PackedStringArray), _credit_line(entry)])
		_pending.append(index)
		if entry["path"] == selected_path:
			_grid.select(index)
			_selected = entry
			_viewed = entry
	set_process(true)
	_say("%d assets" % _shown.size() if _shown.size() != _entries.size() else HINT)
	_refresh_detail()


## Our own picture of a model or a scene has arrived. Without one (a scene too large to put on a stage,
## or not a 3D one), the editor's thumbnail is asked for instead.
func _on_stage_thumbnail(path: String, texture: Texture2D, request: Array) -> void:
	if request[0] != _generation:
		return
	if texture != null:
		_set_thumbnail(path, texture, request)
	else:
		EditorInterface.get_resource_previewer().queue_resource_preview(path, self, &"_on_preview", request)


## The editor's thumbnail has arrived, or null when it has none: the kind's icon stays.
func _on_preview(path: String, preview: Texture2D, _small: Texture2D, request: Array) -> void:
	_set_thumbnail(path, preview, request)


func _set_thumbnail(path: String, texture: Texture2D, request: Array) -> void:
	if texture == null or request[0] != _generation:
		return
	_grid.set_item_icon(request[1], _badged(texture, _shown[request[1]]))
	if _selected.get("path", "") == path and not _stage.has_content():
		_picture.texture = texture


# --- Events ----------------------------------------------------------------------------------------


## The library costs nothing while its tab is closed: no listing, no thumbnail. At the editor's start in
## particular, it waits to be opened.
func _on_visibility_changed() -> void:
	if is_visible_in_tree() and _stale:
		_scan()


func _on_files_changed() -> void:
	_stale = true
	if is_visible_in_tree():
		_rescan.start()


func _on_category_selected(index: int) -> void:
	_category = _categories.get_item_metadata(index)
	_refresh_tags()
	_refresh_grid()


func _on_tag_pressed(tag: String) -> void:
	_tag = "" if _tag == tag else tag
	_refresh_tags()
	_refresh_grid()


func _on_search_changed(_text: String) -> void:
	_refresh_grid()


func _on_uncredited_toggled(_pressed: bool) -> void:
	_refresh_grid()


func _on_zoom_changed(value: float) -> void:
	_apply_zoom(value)
	EditorInterface.get_editor_settings().set_project_metadata(SETTINGS_SECTION, ZOOM_SETTING, value)


## Size the grid's cells for thumbnails of [param size] pixels (at 100 % editor scale).
func _apply_zoom(size: float) -> void:
	_grid.fixed_icon_size = Vector2i.ONE * int(size * _scale())
	_grid.fixed_column_width = int((size + NAME_MARGIN) * _scale())


## Ctrl + wheel over the grid zooms, as it does in the editor's own views.
func _on_grid_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button == null or not button.pressed or not button.ctrl_pressed:
		return
	if button.button_index == MOUSE_BUTTON_WHEEL_UP:
		_zoom.value += _zoom.step
	elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_zoom.value -= _zoom.step
	else:
		return
	_grid.accept_event()


func _on_grid_selected(index: int, selected: bool) -> void:
	if not selected:
		return
	_selected = _shown[index]
	_viewed = _selected
	_refresh_detail()
	if _selected["category"] == Catalog.SOUND and _auto_play.button_pressed:
		_play_sound(_selected["path"])


func _on_grid_activated(index: int) -> void:
	var entry: Dictionary = _shown[index]
	if entry["category"] == Catalog.SOUND:
		_play_sound(entry["path"])
	elif entry["type"] == "PackedScene":
		EditorInterface.open_scene_from_path(entry["path"])
	else:
		EditorInterface.edit_resource(load(entry["path"]))


func _on_stage_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion != null and motion.button_mask & MOUSE_BUTTON_MASK_LEFT:
		_stage.orbit(motion.relative * ORBIT_SPEED)
	elif motion != null and motion.button_mask & (MOUSE_BUTTON_MASK_RIGHT | MOUSE_BUTTON_MASK_MIDDLE):
		_stage.pan(motion.relative / maxf(_stage_box.size.y, 1.0))
	var button := event as InputEventMouseButton
	if button != null and button.pressed:
		if button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_stage.zoom(ZOOM_STEP)
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_stage.zoom(1.0 / ZOOM_STEP)


# --- The selected asset ----------------------------------------------------------------------------


## The detail column shows [member _viewed]: the selected asset, or the one of its levels of detail
## that was picked there.
func _refresh_detail() -> void:
	var chosen := not _viewed.is_empty()
	_empty.visible = not chosen
	for control: Control in [_picture, _stage_box, _sound_row, _lod_row, _name, _info, _action, _locate]:
		control.visible = chosen
	_stage.clear()
	if not chosen:
		return
	var category: StringName = _viewed["category"]
	_name.text = _viewed["name"]
	_info.text = "%s\n%s\n%s" % [
			_viewed["type"], ", ".join(_viewed["tags"] as PackedStringArray), _credit_line(_viewed)]
	_stage_box.visible = false
	_sound_row.visible = category == Catalog.SOUND
	_refresh_lod_row()
	_picture.texture = _type_icon(_viewed)
	var index := _shown.find(_selected)
	if index >= 0 and _grid.get_item_icon(index) != null:
		_picture.texture = _grid.get_item_icon(index)
	_action.visible = category != Catalog.SOUND
	match category:
		Catalog.MODEL, Catalog.SCENE:
			_action.text = "Add to scene"
			_show_on_stage(_viewed["path"])
		Catalog.MATERIAL:
			_action.text = "Apply to selection"
		_:
			_action.text = "Open"
	_refresh_play_button()


## One button a level of detail of the selected asset: picking one shows that level, and the actions
## below then apply to it.
func _refresh_lod_row() -> void:
	for child in _lod_row.get_children():
		_lod_row.remove_child(child)
		child.queue_free()
	var levels: Array = _selected.get("lods", [])
	_lod_row.visible = levels.size() > 1
	for level: Dictionary in levels:
		var button := Button.new()
		button.text = "LOD %d" % maxi(int(level["lod"]), 0)
		button.toggle_mode = true
		button.button_pressed = level["path"] == _viewed["path"]
		button.tooltip_text = level["path"]
		button.pressed.connect(_on_lod_pressed.bind(level))
		_lod_row.add_child(button)


func _on_lod_pressed(level: Dictionary) -> void:
	_viewed = level
	_refresh_detail()


## Put the selected model on the detail's stage, once loaded and if it is still the selected one.
func _show_on_stage(path: String) -> void:
	var node: Node3D = await _thumbnailer.stage_node(path)
	if node == null:
		return
	if _viewed.get("path", "") != path:
		node.free()
		_thumbnailer.settle(path)
		return
	_stage.show_node(node)
	_thumbnailer.settle(path)
	_picture.visible = false
	_stage_box.visible = true


func _run_action() -> void:
	if _viewed.is_empty():
		return
	match _viewed["category"]:
		Catalog.MODEL, Catalog.SCENE:
			_add_to_scene(_viewed)
		Catalog.MATERIAL:
			_apply_material(_viewed)
		_:
			EditorInterface.edit_resource(load(_viewed["path"]))


## Instance the asset under the selected node, or under the scene's root. One undo step.
func _add_to_scene(entry: Dictionary) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		_say("Open a scene first.")
		return
	var resource: Resource = load(entry["path"])
	var node: Node = null
	if resource is PackedScene:
		node = (resource as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	elif resource is Mesh:
		var instance := MeshInstance3D.new()
		instance.mesh = resource
		instance.name = String(entry["name"]).to_pascal_case()
		node = instance
	if node == null:
		_say("%s cannot be instanced." % entry["name"])
		return
	var selection := EditorInterface.get_selection()
	var picked := selection.get_selected_nodes()
	var parent: Node = picked[0] if picked.size() == 1 else root
	var history := EditorInterface.get_editor_undo_redo()
	history.create_action("Add %s to the scene" % entry["name"], UndoRedo.MERGE_DISABLE, root)
	history.add_do_method(parent, &"add_child", node, true)
	history.add_do_method(node, &"set_owner", root)
	history.add_do_reference(node)
	history.add_undo_method(parent, &"remove_child", node)
	history.commit_action()
	selection.clear()
	selection.add_node(node)
	_say("%s added under %s." % [node.name, parent.name])


## Set the material as the override of every selected mesh. One undo step.
func _apply_material(entry: Dictionary) -> void:
	var material := load(entry["path"]) as Material
	var targets: Array[GeometryInstance3D] = []
	for node in EditorInterface.get_selection().get_selected_nodes():
		if node is GeometryInstance3D:
			targets.append(node)
	if material == null or targets.is_empty():
		_say("Select a MeshInstance3D in the scene first.")
		return
	var history := EditorInterface.get_editor_undo_redo()
	history.create_action("Apply %s" % entry["name"])
	for target in targets:
		history.add_do_property(target, &"material_override", material)
		history.add_undo_property(target, &"material_override", target.material_override)
	history.commit_action()
	_say("%s applied to %d node(s)." % [entry["name"], targets.size()])


func _show_in_file_system() -> void:
	if not _viewed.is_empty():
		EditorInterface.select_file(_viewed["path"])


# --- Sound -----------------------------------------------------------------------------------------


func _play_sound(path: String) -> void:
	var stream := load(path) as AudioStream
	if stream == null:
		return
	_player.stream = stream
	_player.play()
	_say("%s  (%.1f s)" % [path.get_file(), stream.get_length()])
	_refresh_play_button()


func _toggle_sound() -> void:
	if _player.playing:
		_player.stop()
		_refresh_play_button()
	elif not _selected.is_empty():
		_play_sound(_selected["path"])


func _refresh_play_button() -> void:
	_play.text = "Stop" if _player.playing else "Play"
	_play.icon = _icon(&"Stop" if _player.playing else &"Play")


func _on_volume_changed(value: float) -> void:
	_player.volume_db = linear_to_db(maxf(value, 0.0001))


# --- Helpers ---------------------------------------------------------------------------------------


func _say(text: String) -> void:
	_status.text = text


func _scale() -> float:
	return EditorInterface.get_editor_scale()


## One of the editor's own icons, or none if this editor does not have it.
func _icon(icon_name: StringName) -> Texture2D:
	var theme := EditorInterface.get_editor_theme()
	if theme != null and theme.has_icon(icon_name, &"EditorIcons"):
		return theme.get_icon(icon_name, &"EditorIcons")
	return null


## [param texture] with the asset's marks in its corners. Top right, its credit: a green tick when the
## project has it, a red cross when it needs one and has none. Bottom left, "LOD" when the asset has
## several levels of detail. Top left, under "All", the icon of its category. Unchanged for an asset
## with none of them.
func _badged(texture: Texture2D, entry: Dictionary) -> Texture2D:
	var has_lods := (entry["lods"] as Array).size() > 1
	# Under "All", two assets of one name sit side by side (a model and its scene): the kind tells them
	# apart. Under a category, every tile is of that kind and the mark would say nothing.
	var kind: Image = _kind_mark(entry["category"]) if _category == Catalog.ALL else null
	if texture == null or not (entry["needs_credit"] or has_lods or kind != null):
		return texture
	var mark: Image = null
	if entry["needs_credit"]:
		mark = _badge(&"StatusSuccess" if entry["credit"] != "" else &"StatusError")
	var picture := texture.get_image()
	if (mark == null and not has_lods and kind == null) or picture == null or picture.is_empty():
		return texture
	if picture.is_compressed():
		picture.decompress()
	picture.convert(Image.FORMAT_RGBA8)
	var side := BADGE_CANVAS
	# Fitted in the canvas. A kind's icon is small: enlarged only so far, it stays an icon.
	var fit := minf(MAX_ICON_ENLARGEMENT, minf(float(side) / picture.get_width(), float(side) / picture.get_height()))
	picture.resize(maxi(1, int(picture.get_width() * fit)), maxi(1, int(picture.get_height() * fit)))
	var canvas := Image.create(side, side, false, Image.FORMAT_RGBA8)
	canvas.blit_rect(picture, Rect2i(Vector2i.ZERO, picture.get_size()), (Vector2i(side, side) - picture.get_size()) / 2)
	if mark != null:
		canvas.blend_rect(mark, Rect2i(Vector2i.ZERO, mark.get_size()), Vector2i(side - mark.get_width(), 0))
	if kind != null:
		canvas.blend_rect(kind, Rect2i(Vector2i.ZERO, kind.get_size()), Vector2i.ZERO)
	if has_lods:
		var lod_mark := _lod_mark()
		canvas.blend_rect(lod_mark, Rect2i(Vector2i.ZERO, lod_mark.get_size()), Vector2i(0, side - lod_mark.get_height()))
	return ImageTexture.create_from_image(canvas)


## The icon of a category on a dark plate, made once a category.
func _kind_mark(category: StringName) -> Image:
	var key := StringName("kind:%s" % category)
	if not _badges.has(key):
		var plate: Image = null
		for item: Array in Catalog.CATEGORIES:
			var icon := _icon(item[2]) if item[0] == category else null
			var image: Image = icon.get_image() if icon != null else null
			if image == null or image.is_empty():
				continue
			if image.is_compressed():
				image.decompress()
			image.convert(Image.FORMAT_RGBA8)
			var side := int(BADGE_CANVAS * KIND_SHARE)
			var padding := side / 5
			image.resize(side, side)
			plate = Image.create(side + 2 * padding, side + 2 * padding, false, Image.FORMAT_RGBA8)
			plate.fill(Color(0.05, 0.05, 0.05, 0.8))
			plate.blend_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), Vector2i(padding, padding))
		_badges[key] = plate
	return _badges[key]


## The word "LOD" on a dark plate, drawn cell by cell from LOD_LETTERS: an image has no font to write
## with. Made once.
func _lod_mark() -> Image:
	if _lod_plate == null:
		var cell := BADGE_CANVAS / LOD_CELLS_ACROSS
		var columns := LOD_LETTERS[0].length() + 2 * LOD_PADDING
		var rows := LOD_LETTERS.size() + 2 * LOD_PADDING
		_lod_plate = Image.create(columns * cell, rows * cell, false, Image.FORMAT_RGBA8)
		_lod_plate.fill(Color(0.05, 0.05, 0.05, 0.8))
		for row in LOD_LETTERS.size():
			for column in LOD_LETTERS[row].length():
				if LOD_LETTERS[row][column] == "#":
					var corner := Vector2i(column + LOD_PADDING, row + LOD_PADDING) * cell
					_lod_plate.fill_rect(Rect2i(corner, Vector2i(cell, cell)), Color.WHITE)
	return _lod_plate


## One of the editor's status icons as an image of the mark's size, made once.
func _badge(icon_name: StringName) -> Image:
	if not _badges.has(icon_name):
		var icon := _icon(icon_name)
		var image: Image = icon.get_image() if icon != null else null
		if image != null and not image.is_empty():
			if image.is_compressed():
				image.decompress()
			image.convert(Image.FORMAT_RGBA8)
			image.resize(int(BADGE_CANVAS * BADGE_SHARE), int(BADGE_CANVAS * BADGE_SHARE))
		else:
			image = null
		_badges[icon_name] = image
	return _badges[icon_name]


## What the detail says of the asset's credit.
func _credit_line(entry: Dictionary) -> String:
	if not entry["needs_credit"]:
		return ""
	if entry["credit"] == "":
		return "No credit: add %s.txt beside it." % String(entry["path"]).get_file().get_basename()
	return "Credit: %s" % String(entry["credit"]).get_file()


## The icon of the asset's own class, or of its category when the editor has none for the class.
func _type_icon(entry: Dictionary) -> Texture2D:
	var own := _icon(StringName(entry["type"]))
	if own != null:
		return own
	for category: Array in Catalog.CATEGORIES:
		if category[0] == entry["category"]:
			return _icon(category[2])
	return null
