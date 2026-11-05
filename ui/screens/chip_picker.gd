class_name ChipPicker
extends Control

## A filter on one line of chips, for the in-world screens: the chosen chip first, then as many others
## as fit, then "…" when some do not — "…" opens a list of them all with a search field that narrows
## it as one types (accents and case ignored). Pressing the chosen chip again un-chooses it: no
## "all" chip to take room. Laid out by hand rather than by a container, so a long line never widens
## the screen it is on. The list opens over the whole screen (its viewport), closed by a choice or a
## press beside it.

## The value chosen ("" = none), and when it changes.
signal chosen(value: String)

const MORE: String = "…"
const GAP_PX: float = 8.0
const LIST_WIDTH_PX: float = 420.0
const LIST_ROW_PX: float = 46.0

## The chosen value, "" for none.
var selected: String = ""
## The screen's colour: the chosen chip.
var accent: Color = Color.WHITE
var ink: Color = Color(0.92, 0.93, 0.95)
var font_px: int = 20
var chip_px: float = 44.0
## The search field's hint (a translation key).
var search_key: String = "%%SCREEN_SEARCH"

## {value, text, colour (Color, optional), icon (Texture2D, optional)} in the order to offer them.
var _options: Array = []
var _list: Control = null
var _search: LineEdit = null
var _rows: VBoxContainer = null


func _init() -> void:
	clip_contents = true
	custom_minimum_size = Vector2(0, chip_px)


## Offer [param options] ({value, text, colour?, icon?}); a choice no longer offered is dropped.
func set_options(options: Array) -> void:
	_options = options
	if selected != "" and not _values().has(selected):
		selected = ""
	_relayout()


## Whether the search field has the keyboard (the screen's is_typing).
func is_typing() -> bool:
	return _search != null and _search.has_focus()


## Close the list if it is open.
func close_list() -> void:
	if _list != null:
		_list.queue_free()
		_list = null
		_search = null
		_rows = null


## Whether [param text] matches what was typed, [param query]: every word of it found in the text,
## accents and case ignored ("geo cany" finds "Relevés géologiques du canyon").
static func matches(text: String, query: String) -> bool:
	var haystack: String = fold(text)
	for word: String in fold(query).split(" ", false):
		if not haystack.contains(word):
			return false
	return true


## [param text] in lower case and without accents, for matching.
static func fold(text: String) -> String:
	var out: String = text.to_lower()
	for pair: Array in [["àâä", "a"], ["éèêë", "e"], ["îï", "i"], ["ôö", "o"], ["ùûü", "u"], ["ç", "c"]]:
		for accented: String in pair[0]:
			out = out.replace(accented, pair[1])
	return out


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_relayout()


func _values() -> Array:
	return _options.map(func(o: Dictionary) -> String: return str(o["value"]))


## The chips that fit, the chosen one first, and "…" for the others.
func _relayout() -> void:
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	var order: Array = _options.filter(func(o: Dictionary) -> bool: return str(o["value"]) == selected)
	order.append_array(_options.filter(func(o: Dictionary) -> bool: return str(o["value"]) != selected))
	# Measured once in the tree: a button out of it does not know its text's width yet.
	var more := _chip({"value": "", "text": MORE}, false)
	more.pressed.connect(_open_list)
	var more_w: float = _measure(more)
	var x: float = 0.0
	var shown: int = 0
	for option: Dictionary in order:
		var chip := _chip(option, str(option["value"]) == selected)
		var w: float = _measure(chip)
		var room: float = size.x - (more_w + GAP_PX if shown < order.size() - 1 else 0.0)
		if size.x > 0.0 and x + w > room:
			if shown > 0:
				remove_child(chip)
				chip.free()
				break
			# The chosen chip alone is wider than the line: its text is cut, never the line.
			chip.clip_text = true
			chip.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			w = maxf(room - x, chip_px)
		chip.pressed.connect(_toggle.bind(str(option["value"])))
		chip.position = Vector2(x, 0)
		chip.size = Vector2(w, chip_px)
		x += w + GAP_PX
		shown += 1
	if shown < order.size():
		move_child(more, -1)
		more.position = Vector2(x, 0)
		more.size = Vector2(more_w, chip_px)
	else:
		remove_child(more)
		more.free()


## [param chip]'s width, once it is in the line (where its font is known).
func _measure(chip: Button) -> float:
	add_child(chip)
	return chip.get_combined_minimum_size().x


func _toggle(value: String) -> void:
	_choose("" if value == selected else value)


func _choose(value: String) -> void:
	close_list()
	selected = value
	_relayout()
	chosen.emit(selected)


func _chip(option: Dictionary, on: bool) -> Button:
	var chip := Button.new()
	chip.text = str(option["text"])
	chip.focus_mode = Control.FOCUS_NONE
	chip.custom_minimum_size = Vector2(0, chip_px)
	AresBrand.style_button(chip, Color(accent, 0.25) if on else Color(1, 1, 1, 0.05), accent if on else ink, font_px)
	if option.get("colour") is Color and not on:
		chip.add_theme_color_override("font_color", option["colour"])
		chip.add_theme_color_override("font_hover_color", option["colour"])
	if option.get("icon") is Texture2D:
		chip.icon = option["icon"]
		chip.expand_icon = true
		chip.add_theme_constant_override("icon_max_width", font_px + 8)
	return chip


## The list of every option under the line, over the screen, its search field ready to type in.
func _open_list() -> void:
	close_list()
	var host: Viewport = get_viewport()
	if host == null:
		return
	var screen: Vector2 = host.get_visible_rect().size
	_list = Control.new()
	_list.set_anchors_preset(Control.PRESET_FULL_RECT)
	_list.mouse_filter = Control.MOUSE_FILTER_STOP
	_list.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			close_list())
	host.add_child(_list)

	var panel := PanelContainer.new()
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.09, 0.1, 0.12)
	box.border_color = accent
	box.set_border_width_all(2)
	box.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", box)
	var at: Vector2 = global_position + Vector2(0, chip_px + 4)
	var width: float = minf(LIST_WIDTH_PX, screen.x - at.x - 8)
	panel.position = Vector2(clampf(at.x, 8, screen.x - width - 8), at.y)
	panel.custom_minimum_size = Vector2(width, 0)
	_list.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	panel.add_child(column)
	_search = LineEdit.new()
	_search.placeholder_text = search_key
	_search.add_theme_font_size_override("font_size", font_px)
	if AresBrand.font() != null:
		_search.add_theme_font_override("font", AresBrand.font())
	_search.text_changed.connect(func(_t: String) -> void: _fill_list())
	_search.text_submitted.connect(func(_t: String) -> void: _choose_first())
	column.add_child(_search)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, minf(_options.size(), 7) * LIST_ROW_PX)
	column.add_child(scroll)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows)
	_fill_list()
	_search.grab_focus()


func _fill_list() -> void:
	if _rows == null:
		return
	for child: Node in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	for option: Dictionary in _options:
		if not matches(TranslationServer.translate(str(option["text"])), _search.text):
			continue
		var row := _chip(option, str(option["value"]) == selected)
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.custom_minimum_size = Vector2(0, LIST_ROW_PX)
		row.pressed.connect(_toggle.bind(str(option["value"])))
		_rows.add_child(row)


func _choose_first() -> void:
	if _rows != null and _rows.get_child_count() > 0:
		(_rows.get_child(0) as Button).pressed.emit()
