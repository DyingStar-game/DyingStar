class_name ServiceTargetPicker
extends VBoxContainer

## Tap-to-pick the target of an action — contacts, a searched player, my corporations, a searched
## corporation — so a uuid is never typed by hand: the sources show names, a row click IS the pick,
## and the chip displays the chosen id for verification only.
##
## The visible sources follow the mask set by [method setup] / [method set_mask] (players,
## corporations, either). Changing the mask clears any current pick, so a player id can never be
## submitted as a corporation — or the reverse. The search field belongs to the host panel's
## keyboard contract: panels call adopt_field(picker.search_field()) once after setup().
##
## Built for two homes. A whole page can host it open ([code]setup(mask)[/code] — Banque,
## Signalements); a dense form hosts it collapsed ([code]setup(mask, true)[/code]): a single
## « Choose… » button stands in for the sources, the body unfolds on tap, and the pick collapses it
## back — the chip, which carries the choice, always stays visible.

## A row was picked (or re-picked). [param kind] is KIND_PLAYER or KIND_CORPORATION.
signal picked(target_id: String, kind: String)

enum Mask { PLAYERS, CORPORATIONS, EITHER }

const KIND_PLAYER := "player"
const KIND_CORPORATION := "corporation"

const SRC_CONTACTS := "contacts"
const SRC_PLAYERS := "players"
const SRC_MY_CORPS := "my_corps"
const SRC_CORPS := "corps"

## Rows a source shows at once: the API's own maximum, so the picker never needs a footer of its
## own — and the note below the rows says when even that is not all of them.
const PICK_LIMIT: int = 100

var _mask: int = Mask.EITHER
var _source: String = SRC_CONTACTS
var _source_row: HBoxContainer
var _source_buttons: Dictionary = {}
var _search_row: HBoxContainer
var _search: LineEdit
var _results: VBoxContainer
var _body: VBoxContainer
var _toggle: Button
var _chip_row: HBoxContainer
var _chip: Label
var _picked_id: String = ""
var _picked_kind: String = ""
## True when the host asked for the collapsed form; false keeps the body open for good.
var _collapsible: bool = false
var _open: bool = true
## Rows already fetched for the current source: a collapsed picker fetches on its first open, not
## at build time — a form holding several of them must not cost an HTTP round each.
var _loaded: bool = false


## Build the picker for one mask and open its first source. Call once from the host's _build().
## [param collapsed] wraps the sources in a one-button expander, for forms that cannot spare the
## full block.
func setup(mask: int, collapsed: bool = false) -> void:
	add_theme_constant_override("separation", 8)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mask = mask
	_collapsible = collapsed
	_open = not collapsed

	if _collapsible:
		_toggle = Button.new()
		_toggle.text = tr("%%SVC_ACT_CHOOSE")
		ServiceStyle.apply_button(_toggle)
		_toggle.pressed.connect(func() -> void: _set_open(not _open))
		add_child(_toggle)

	# Everything the expander hides lives in one box; the chip is a sibling, so the choice it
	# carries survives a collapse.
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 8)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_body)

	_source_row = HBoxContainer.new()
	_source_row.add_theme_constant_override("separation", 6)
	_body.add_child(_source_row)
	_add_source(SRC_CONTACTS, tr("%%SVC_TAB_CONTACTS"))
	_add_source(SRC_PLAYERS, tr("%%SVC_LBL_SRC_PLAYERS"))
	_add_source(SRC_MY_CORPS, tr("%%SVC_TAB_MY_CORPS"))
	_add_source(SRC_CORPS, tr("%%SVC_LBL_SRC_CORPS"))

	# Search only makes sense on the two search sources; the row hides elsewhere.
	_search_row = HBoxContainer.new()
	_search_row.add_theme_constant_override("separation", 6)
	_search = LineEdit.new()
	_search.placeholder_text = tr("%%SVC_PH_SEARCH")
	_search.custom_minimum_size = Vector2(240, 40)
	ServiceStyle.apply_field(_search)
	_search.text_submitted.connect(func(_text: String) -> void: _run_search())
	_search_row.add_child(_search)
	var browse := Button.new()
	browse.text = tr("%%SVC_ACT_BROWSE")
	ServiceStyle.apply_button(browse)
	browse.pressed.connect(func() -> void: _run_search())
	_search_row.add_child(browse)
	_body.add_child(_search_row)

	# Results — a bounded scroll so the host form never grows without limit.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 150)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_results = VBoxContainer.new()
	_results.add_theme_constant_override("separation", 6)
	_results.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_results)
	_body.add_child(scroll)

	# Pick chip: the choice in words, its id for verification, and a way out.
	_chip_row = HBoxContainer.new()
	_chip_row.add_theme_constant_override("separation", 8)
	_chip = Label.new()
	_chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_chip.add_theme_color_override("font_color", ServiceStyle.ACCENT)
	ServiceStyle.font_of(_chip, 14, true)
	_chip_row.add_child(_chip)
	var clear := Button.new()
	clear.text = "×"
	ServiceStyle.apply_button(clear)
	clear.pressed.connect(func() -> void: clear_pick())
	_chip_row.add_child(clear)
	add_child(_chip_row)
	_chip_row.visible = false

	_apply_mask_visibility()
	_source = _first_visible_source()
	_sync_source_ui()
	_body.visible = _open
	if _open:
		_load_source()


## The search input — the host panel adopts it into its keyboard contract ([method ServicePanel
## .adopt_field]) so typing never leaks into gameplay.
func search_field() -> LineEdit:
	return _search


func picked_id() -> String:
	return _picked_id


func picked_kind() -> String:
	return _picked_kind


## Drop the current pick (chip and ids); the open source stays.
func clear_pick() -> void:
	_picked_id = ""
	_picked_kind = ""
	_chip.text = ""
	_chip_row.visible = false


## The expander's state: body shown or hidden, button worded for the action it offers next. The
## first open is also the first fetch — nothing was loaded while the rows were invisible.
func _set_open(open: bool) -> void:
	if not _collapsible:
		return
	_open = open
	_body.visible = open
	_toggle.text = tr("%%SVC_ACT_CLOSE") if open else tr("%%SVC_ACT_CHOOSE")
	if open:
		if not _loaded:
			_load_source()
	elif _search != null and _search.has_focus():
		_search.release_focus()


## New mask: sources outside it disappear, an invisible source falls back to the first visible
## one, and any pick is dropped — an id chosen under the old mask must never cross over.
func set_mask(mask: int) -> void:
	_mask = mask
	_apply_mask_visibility()
	if not _source_visible(_source):
		_source = _first_visible_source()
		_sync_source_ui()
		_loaded = false
		if _open:
			_load_source()
	clear_pick()


func _apply_mask_visibility() -> void:
	for source: String in _source_buttons:
		(_source_buttons[source] as Button).visible = _source_visible(source)


func _source_visible(source: String) -> bool:
	if source == SRC_CONTACTS or source == SRC_PLAYERS:
		return _mask == Mask.PLAYERS or _mask == Mask.EITHER
	return _mask == Mask.CORPORATIONS or _mask == Mask.EITHER


func _first_visible_source() -> String:
	for source: String in [SRC_CONTACTS, SRC_PLAYERS, SRC_MY_CORPS, SRC_CORPS]:
		if _source_visible(source):
			return source
	return SRC_CONTACTS


func _add_source(id: String, label: String) -> void:
	var button := Button.new()
	button.text = label
	ServiceStyle.apply_segment(button, false)
	button.pressed.connect(func() -> void: _show_source(id))
	_source_row.add_child(button)
	_source_buttons[id] = button


## Switch the active source: segment states, search row visibility, then load its rows.
func _show_source(source: String) -> void:
	_source = source
	_sync_source_ui()
	_load_source()


## Which source button reads as active, and whether the search row belongs to it.
func _sync_source_ui() -> void:
	for key: String in _source_buttons:
		var button := _source_buttons[key] as Button
		button.set_pressed_no_signal(key == _source)
		ServiceStyle.apply_segment(button, key == _source)
	_search_row.visible = _source == SRC_PLAYERS or _source == SRC_CORPS


## Fetch (or search) the active source's rows. Fire-and-forget: the rows fill when the answer
## lands, exactly like the panels' refresh().
func _load_source() -> void:
	_loaded = true
	_clear_results()
	match _source:
		SRC_CONTACTS:
			var contacts: Dictionary = await PlayerServices.friends_list(PICK_LIMIT)
			_fill_rows(contacts, tr("%%SVC_MSG_NO_CONTACTS"), KIND_PLAYER, true)
		SRC_MY_CORPS:
			var mine: Dictionary = await PlayerServices.my_corporations(PICK_LIMIT)
			_fill_rows(mine, tr("%%SVC_MSG_NO_CORPS"), KIND_CORPORATION, false)
		_:
			_run_search()


func _run_search() -> void:
	_clear_results()
	var query := _search.text.strip_edges()
	if _source == SRC_PLAYERS:
		var players: Dictionary = await PlayerServices.profiles_search(query, PICK_LIMIT)
		_fill_rows(players, tr("%%SVC_MSG_NO_RESULTS"), KIND_PLAYER, false)
	else:
		var corps: Dictionary = await PlayerServices.corporations_list(query, PICK_LIMIT)
		_fill_rows(corps, tr("%%SVC_MSG_NO_RESULTS"), KIND_CORPORATION, false)


## One tappable row per result; clicking it is the pick.
func _fill_rows(result: Dictionary, empty_text: String, kind: String, with_presence: bool) -> void:
	_clear_results()
	if not bool(result.get("ok", false)):
		var error := Label.new()
		error.text = HttpClient.describe_error(result)
		error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		error.add_theme_color_override("font_color", ServiceStyle.WARN)
		ServiceStyle.font_of(error, 14)
		_results.add_child(error)
		return
	var count := 0
	for entry: Dictionary in ServicePage.items_of(result):
		_results.add_child(_row_button(entry, kind, with_presence))
		count += 1
	if count == 0:
		var empty := Label.new()
		empty.text = empty_text
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.add_theme_color_override("font_color", ServiceStyle.MUTED)
		ServiceStyle.font_of(empty, 14)
		_results.add_child(empty)
		return
	# The window is wide, but it is still a window: say so when the source does not fit in it.
	var total: int = ServicePage.total_of(result, PackedStringArray(["total"]))
	if total > count:
		var more := Label.new()
		more.text = tr("%%SVC_MSG_MORE_RESULTS") % (total - count)
		more.add_theme_color_override("font_color", ServiceStyle.MUTED)
		ServiceStyle.font_of(more, 13)
		_results.add_child(more)


func _row_button(entry: Dictionary, kind: String, with_presence: bool) -> Button:
	var button := Button.new()
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.custom_minimum_size = Vector2(0, 56)
	ServiceStyle.apply_tile(button)

	var content := HBoxContainer.new()
	content.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.offset_left = 10.0
	content.offset_right = -10.0
	content.add_theme_constant_override("separation", 10)
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var display_name := str(entry.get("displayName", entry.get("name", "?")))
	var status := str(entry.get("status", ""))
	content.add_child(ServicePanel._avatar_initial(display_name, 38.0, status if with_presence else ""))
	var texts := VBoxContainer.new()
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.add_theme_constant_override("separation", 0)
	texts.alignment = BoxContainer.ALIGNMENT_CENTER
	texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name_label := Label.new()
	name_label.text = display_name
	name_label.add_theme_color_override("font_color", ServiceStyle.TEXT)
	ServiceStyle.font_of(name_label, 15, true)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.add_child(name_label)
	var sub := Label.new()
	sub.text = _subtitle(entry, kind, with_presence)
	sub.add_theme_color_override("font_color", ServiceStyle.MUTED)
	ServiceStyle.font_of(sub, 12)
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.add_child(sub)
	content.add_child(texts)
	button.add_child(content)

	var target_id := str(entry.get("playerId", entry.get("id", "")))
	button.pressed.connect(func() -> void: _select(target_id, kind, display_name))
	return button


## Rows differ by source: presence for contacts, kind · reputation for a searched profile, the
## corporation's ticker and size for a corp.
func _subtitle(entry: Dictionary, kind: String, with_presence: bool) -> String:
	if kind == KIND_PLAYER:
		if with_presence:
			return ServiceTypes.presence(entry.get("status"))
		return "%s · rep %d" % [ServiceTypes.entity_type_label(entry.get("entityType")),
				ServiceTypes.num(entry.get("reputation"))]
	return "%s · %d" % [ServiceTypes.dash(entry.get("ticker")),
			ServiceTypes.num(entry.get("memberCount"))]


func _select(target_id: String, kind: String, display: String) -> void:
	if target_id == "":
		return
	set_pick(target_id, kind, display)
	# A collapsed picker folds itself away: the pick is the answer, the form gets its room back.
	if _collapsible:
		_set_open(false)


## A pick made outside the picker (a corporation tile tapped on another tab, say) lands here
## already resolved: id, kind, and the name the chip shows.
func set_pick(target_id: String, kind: String, display: String) -> void:
	if target_id == "":
		return
	_picked_id = target_id
	_picked_kind = kind
	_chip.text = "%s : %s (%s)" % [tr("%%SVC_LBL_SELECTED"), display, target_id]
	_chip_row.visible = true
	picked.emit(target_id, kind)



func _clear_results() -> void:
	for child: Node in _results.get_children():
		_results.remove_child(child)
		child.queue_free()
