class_name ServicePanel
extends VBoxContainer

## Shared look and building blocks for the terminal's sections. Every section is a plain [Control]
## built in code — no scene, no shared theme. The look itself lives in [ServiceStyle]; this file only
## wires it to the widgets the sections use.
##
## The section is SELF-CONTAINED: it reads and mutates through the [PlayerServices] autoload and
## refreshes itself. It still exposes the screen contract the console relies on — [method is_typing]
## and [method release_fields] — so the owning structure can shield gameplay input while a field has
## the keyboard.

## The tablet asks a panel to leave its app and go back to the overview (the app bar's « Accueil »
## button emits this; TerminalUI routes it).
signal home_requested

## Kept as the sections' unqualified vocabulary; all sourced from [ServiceStyle].
const ACCENT: Color = ServiceStyle.ACCENT
const DIM: Color = ServiceStyle.MUTED
const WARN: Color = ServiceStyle.WARN
const GOOD: Color = ServiceStyle.GOOD
const BG_COLOR: Color = ServiceStyle.BG
const FONT_PATH: String = "res://ui/Poppins-Regular.ttf"

## Focusable inputs registered here, so the screen contract can answer for all of them.
var _fields: Array[LineEdit] = []
var _text_areas: Array[TextEdit] = []
var _status: Label = null
var _status_panel: PanelContainer = null
var _status_timer: Timer = null
## The last segmented control built, so [method goto_segment] can switch it in code.
var _seg_bar: HBoxContainer = null
var _seg_holders: Array[ScrollContainer] = []
## Guards against overlapping refreshes (rapid section switches): a second refresh is skipped while
## one is in flight.
var _loading: bool = false


func _ready() -> void:
	add_theme_constant_override("separation", 14)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	# A status only lingers a few seconds: it is a transient result, not a permanent banner.
	_status_timer = Timer.new()
	_status_timer.one_shot = true
	_status_timer.wait_time = 5.0
	_status_timer.timeout.connect(_clear_status)
	add_child(_status_timer)
	_build()


## Sections override this to lay themselves out. Called once, from _ready.
func _build() -> void:
	pass


## Reload the section's data from the services. Sections override.
func refresh() -> void:
	pass


# ---------------------------------------------------------------------------------------------
# Screen contract
# ---------------------------------------------------------------------------------------------

## True while one of our inputs holds the keyboard. The owning console relays this so the game stops
## acting on what is being typed (gameplay polls [Input], which a focused LineEdit cannot consume).
func is_typing() -> bool:
	for field: LineEdit in _fields:
		if field != null and field.has_focus():
			return true
	for area: TextEdit in _text_areas:
		if area != null and area.has_focus():
			return true
	return false


## Give the keyboard back to the game (Escape, or walking away).
func release_fields() -> void:
	for field: LineEdit in _fields:
		if field != null and field.has_focus():
			field.release_focus()
	for area: TextEdit in _text_areas:
		if area != null and area.has_focus():
			area.release_focus()


## Adopt a focusable field the panel does not build itself — a composed control's input (the
## target picker's search) — so the screen contract still shields gameplay while it holds the
## keyboard.
func adopt_field(field: LineEdit) -> void:
	_fields.append(field)


# ---------------------------------------------------------------------------------------------
# Building blocks
# ---------------------------------------------------------------------------------------------

## The section's page title.
func _heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", ServiceStyle.TEXT)
	ServiceStyle.font_of(label, 24, true)
	return label


## A group caption: small, spaced capitals over a hairline rule.
func _subheading(text: String) -> Label:
	var label := Label.new()
	label.text = text.to_upper()
	label.add_theme_color_override("font_color", ServiceStyle.MUTED)
	ServiceStyle.font_of(label, 13, true)
	var rule := StyleBoxFlat.new()
	rule.bg_color = Color.TRANSPARENT
	rule.border_width_bottom = 1
	rule.border_color = ServiceStyle.BORDER_STRONG
	rule.content_margin_top = 8.0
	rule.content_margin_bottom = 4.0
	label.add_theme_stylebox_override("normal", rule)
	return label


func _label(text: String, colour: Color = ServiceStyle.MUTED) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", colour)
	ServiceStyle.font_of(label, 14)
	return label


## A text input. Registered for the screen contract.
func _field(placeholder: String, min_width: float = 220.0) -> LineEdit:
	var field := LineEdit.new()
	field.placeholder_text = placeholder
	field.custom_minimum_size = Vector2(min_width, 40)
	ServiceStyle.apply_field(field)
	_fields.append(field)
	return field


## A numeric input (same as _field, but hints and filters).
func _number_field(placeholder: String, min_width: float = 140.0) -> LineEdit:
	var field := _field(placeholder, min_width)
	field.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	return field


## A multi-line text input (a biography, a long message). Registered for the screen contract too.
func _textarea(placeholder: String, min_height: float = 120.0) -> TextEdit:
	var area := TextEdit.new()
	area.placeholder_text = placeholder
	area.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	area.custom_minimum_size = Vector2(0, min_height)
	area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ServiceStyle.apply_textarea(area)
	_text_areas.append(area)
	return area


## A read-only rich-text block (BBCode) for displaying formatted content, sized to its content.
func _rich_text(min_height: float = 0.0) -> RichTextLabel:
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if min_height > 0.0:
		label.custom_minimum_size = Vector2(0, min_height)
	ServiceStyle.apply_rich_text(label, 15)
	return label


## Wrap the current selection of a [TextEdit] in BBCode (or drop the tag pair at the caret). Used by a
## formatting toolbar so the biography can be written in rich text.
func _wrap_bbcode(area: TextEdit, open_tag: String, close_tag: String) -> void:
	if area == null:
		return
	var selected: String = area.get_selected_text()
	if selected != "":
		area.insert_text_at_caret(open_tag + selected + close_tag)
		return
	area.insert_text_at_caret(open_tag + close_tag)
	area.set_caret_column(maxi(area.get_caret_column() - close_tag.length(), 0))


# ---------------------------------------------------------------------------------------------
# Contacts kit: generated avatar + presence
# ---------------------------------------------------------------------------------------------

## The colour a presence status paints with: green online, amber in mission, grey otherwise.
static func _presence_colour(status: String) -> Color:
	match status:
		"online":
			return GOOD
		"mission":
			return ACCENT
		_:
			return DIM


## A small coloured disc for a presence status, ringed so it reads over an avatar. Static, for the
## same reason as [method _avatar_initial]: the composed controls outside the panels draw it too.
static func _presence_dot(status: String) -> Control:
	var dot := Panel.new()
	dot.custom_minimum_size = Vector2(12, 12)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.add_theme_stylebox_override("panel",
			ServiceStyle.flat(_presence_colour(status), 999, ServiceStyle.BG, 2))
	return dot


## A generated avatar: a disc carrying the contact's initial, optionally badged with a presence dot in
## its bottom-right corner. The project ships no portrait set, so the initial IS the portrait. Static
## so composed controls outside the panels (the target picker) can draw the same face.
static func _avatar_initial(name: String, size: float = 44.0, presence: String = "") -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(size, size)
	holder.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var disc := Panel.new()
	disc.set_anchors_preset(Control.PRESET_FULL_RECT)
	disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	disc.add_theme_stylebox_override("panel",
			ServiceStyle.flat(ServiceStyle.ACCENT_SOFT, int(size * 0.5), ServiceStyle.ACCENT_LINE, 1))
	holder.add_child(disc)

	var letter := Label.new()
	letter.set_anchors_preset(Control.PRESET_FULL_RECT)
	letter.text = ServiceTypes.initial(name)
	letter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	letter.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	letter.add_theme_color_override("font_color", ServiceStyle.ACCENT)
	ServiceStyle.font_of(letter, int(size * 0.42), true)
	letter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(letter)

	if presence != "":
		var dot := _presence_dot(presence)
		var d: float = maxf(size * 0.34, 12.0)
		dot.anchor_left = 1.0
		dot.anchor_top = 1.0
		dot.anchor_right = 1.0
		dot.anchor_bottom = 1.0
		dot.offset_left = -d
		dot.offset_top = -d
		dot.offset_right = 0.0
		dot.offset_bottom = 0.0
		holder.add_child(dot)
	return holder


## A status pill (coloured dot + label) for a presence status, used on a contact sheet header.
func _presence_pill(status: String) -> Control:
	var pill := PanelContainer.new()
	pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ServiceStyle.apply_pill(pill, _presence_colour(status))
	var label := _label(ServiceTypes.presence(status), _presence_colour(status))
	label.add_theme_color_override("font_color", _presence_colour(status))
	ServiceStyle.font_of(label, 13, true)
	pill.add_child(label)
	return pill


## A full-width tappable contact row: generated avatar, display name over a muted subtitle.
func _contact_button(profile: Dictionary, subtitle: String, status: String = "") -> Button:
	var row := Button.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.custom_minimum_size = Vector2(0, 60)
	ServiceStyle.apply_tile(row)
	var content := HBoxContainer.new()
	content.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.offset_left = 12.0
	content.offset_right = -12.0
	content.add_theme_constant_override("separation", 12)
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(_avatar_initial(str(profile.get("displayName", "?")), 42.0, status))
	var texts := VBoxContainer.new()
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.add_theme_constant_override("separation", 0)
	texts.alignment = BoxContainer.ALIGNMENT_CENTER
	texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name_label := _label(str(profile.get("displayName", "—")), ServiceStyle.TEXT)
	ServiceStyle.font_of(name_label, 16, true)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.add_child(name_label)
	if subtitle != "":
		var sub := _label(subtitle, ServiceStyle.MUTED)
		sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
		texts.add_child(sub)
	content.add_child(texts)
	row.add_child(content)
	return row


## A contact card used by the action lists: avatar + name + subtitle, then trailing action buttons.
## [param actions] is an array of `[label, Callable]` pairs.
func _contact_card(profile: Dictionary, subtitle: String, status: String, actions: Array) -> Control:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel",
			ServiceStyle.flat(ServiceStyle.PANEL, ServiceStyle.RADIUS, ServiceStyle.BORDER, 1, 14.0, 10.0))
	var row := _row(12)
	card.add_child(row)
	row.add_child(_avatar_initial(str(profile.get("displayName", "?")), 40.0, status))
	var texts := VBoxContainer.new()
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.add_theme_constant_override("separation", 0)
	texts.alignment = BoxContainer.ALIGNMENT_CENTER
	var name_label := _label(str(profile.get("displayName", "—")), ServiceStyle.TEXT)
	ServiceStyle.font_of(name_label, 16, true)
	texts.add_child(name_label)
	if subtitle != "":
		texts.add_child(_label(subtitle, ServiceStyle.MUTED))
	row.add_child(texts)
	for action: Array in actions:
		_action_button(row, str(action[0]), action[1])
	return card


func _list(min_height: float = 160.0) -> ItemList:
	var list := ItemList.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.custom_minimum_size = Vector2(0, min_height)
	list.allow_reselect = true
	ServiceStyle.apply_list(list)
	return list


func _button(text: String, min_width: float = 0.0) -> Button:
	var button := Button.new()
	button.text = text
	if min_width > 0.0:
		button.custom_minimum_size = Vector2(min_width, 40)
	ServiceStyle.apply_button(button)
	return button


## Add a button wired to [param handler] in one call. [method Node.add_child] returns void, so the
## build code cannot chain `add_child(_button(...)).pressed.connect(...)`; this keeps the layout
## sections readable.
func _action_button(parent: Node, text: String, handler: Callable, min_width: float = 0.0) -> Button:
	var button := _button(text, min_width)
	button.pressed.connect(handler)
	parent.add_child(button)
	return button


func _option(items: PackedStringArray, min_width: float = 160.0) -> OptionButton:
	var option := OptionButton.new()
	for item: String in items:
		option.add_item(item)
	option.custom_minimum_size = Vector2(min_width, 40)
	ServiceStyle.apply_option(option)
	return option


## An OptionButton whose labels are localized and whose item metadata keeps the raw API value.
## [param entries] is an array of `[value, translation key]` pairs.
func _option_enum(entries: Array, min_width: float = 160.0) -> OptionButton:
	var option := OptionButton.new()
	for entry: Array in entries:
		option.add_item(tr(str(entry[1])))
		option.set_item_metadata(option.item_count - 1, str(entry[0]))
	option.custom_minimum_size = Vector2(min_width, 40)
	ServiceStyle.apply_option(option)
	return option


## The raw API value behind an [OptionButton]'s selected item (its metadata), or "".
static func _enum_value(option: OptionButton) -> String:
	if option.selected < 0 or option.selected >= option.item_count:
		return ""
	return str(option.get_item_metadata(option.selected))


func _row(separation: int = 10) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", separation)
	return row


func _titled(text: String, body: Control, stretch: bool = false) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	if stretch:
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_subheading(text))
	box.add_child(body)
	return box


## Empty a container of all its children, freeing them. Shared: every section rebuilds its
## dynamic lists (members, invitations, clauses) by clearing first.
static func _clear(box: Node) -> void:
	for child: Node in box.get_children():
		box.remove_child(child)
		child.queue_free()


# ---------------------------------------------------------------------------------------------
# Mobile-app kit: app bar, segmented tabs, pages, empty states
# ---------------------------------------------------------------------------------------------

## An app's top bar: a back-to-overview button, its glyph and title, with room on the right for action
## buttons (added by the caller after this returns — the internal spacer pushes them to the end).
func _app_bar(title: String, icon_kind: ServiceAppIcon.Kind) -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 12)
	bar.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_action_button(bar, "‹  " + tr("%%SVC_ACT_HOME"), func() -> void: home_requested.emit())
	var icon := ServiceAppIcon.new()
	icon.kind = icon_kind
	icon.colour = ServiceStyle.ACCENT
	icon.custom_minimum_size = Vector2(28, 28)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.add_child(icon)
	var label := Label.new()
	label.text = title
	label.add_theme_color_override("font_color", ServiceStyle.TEXT)
	ServiceStyle.font_of(label, 22, true)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar.add_child(label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	return bar


## A segmented control + one scrollable page per segment. Adds the bar and the pages to [code]self[/code]
## and returns the page boxes, in order, for the caller to fill. Pages other than the first start
## hidden. The last built set is remembered so [method goto_segment] can switch to a page in code.
func _segments_pages(labels: PackedStringArray) -> Array[VBoxContainer]:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	bar.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	add_child(bar)

	var pages: Array[VBoxContainer] = []
	var holders: Array[ScrollContainer] = []
	for _i: int in range(labels.size()):
		var page := VBoxContainer.new()
		page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		page.add_theme_constant_override("separation", 12)
		var scroll := ScrollContainer.new()
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.add_child(page)
		add_child(scroll)
		pages.append(page)
		holders.append(scroll)

	for i: int in range(labels.size()):
		var tab := Button.new()
		tab.text = labels[i]
		ServiceStyle.apply_segment(tab, i == 0)
		var index: int = i
		tab.pressed.connect(func() -> void: _show_segment(bar, holders, index))
		bar.add_child(tab)

	_seg_bar = bar
	_seg_holders = holders
	_show_segment(bar, holders, 0)
	return pages


## Switch to the [param index]-th segment built by the last [method _segments_pages] call.
func goto_segment(index: int) -> void:
	if _seg_bar != null and index >= 0 and index < _seg_holders.size():
		_show_segment(_seg_bar, _seg_holders, index)


func _show_segment(bar: HBoxContainer, holders: Array[ScrollContainer], index: int) -> void:
	for i: int in range(bar.get_child_count()):
		ServiceStyle.apply_segment(bar.get_child(i) as Button, i == index)
	for i: int in range(holders.size()):
		holders[i].visible = i == index


## The status footer every section shows the outcome of an action on. Hidden until something is said,
## and hidden again a few seconds later — it is a transient result, never a permanent banner.
func _status_line() -> Control:
	_status_panel = PanelContainer.new()
	_status_panel.add_theme_stylebox_override("panel",
			ServiceStyle.flat(ServiceStyle.PANEL_ALT, ServiceStyle.RADIUS_SMALL,
					ServiceStyle.BORDER, 1, 12.0, 8.0))
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(0, 22)
	_status.add_theme_color_override("font_color", ServiceStyle.MUTED)
	ServiceStyle.font_of(_status, 14)
	_status_panel.add_child(_status)
	_status_panel.visible = false
	return _status_panel


func _say(message: String, colour: Color = ACCENT) -> void:
	if _status == null:
		return
	_status.text = message
	_status.add_theme_color_override("font_color", colour)
	if _status_panel != null:
		_status_panel.visible = message != ""
	if _status_timer != null:
		if message != "":
			_status_timer.start()
		else:
			_status_timer.stop()


func _clear_status() -> void:
	if _status != null:
		_status.text = ""
	if _status_panel != null:
		_status_panel.visible = false


## Report a service result on the status line: the success sentence, or the service's own error.
func _report(result: Dictionary, success: String) -> bool:
	if bool(result.get("ok", false)):
		_say(success, GOOD)
		return true
	_say(HttpClient.describe_error(result), WARN)
	return false


## Take the refresh slot, or report that one is already running. Paired with [method _end_refresh].
func _begin_refresh() -> bool:
	if _loading:
		return false
	_loading = true
	return true


func _end_refresh() -> void:
	_loading = false


## Replace a list's rows with [param lines] (metadata kept alongside for selection handling).
static func _fill_list(list: ItemList, lines: PackedStringArray, metadata: Array = []) -> void:
	list.clear()
	for i: int in range(lines.size()):
		list.add_item(lines[i])
		if i < metadata.size():
			list.set_item_metadata(i, metadata[i])


## The metadata of the selected row, or null when nothing is selected.
static func _selected_meta(list: ItemList) -> Variant:
	var selected: PackedInt32Array = list.get_selected_items()
	if selected.is_empty():
		return null
	return list.get_item_metadata(selected[0])


# ---------------------------------------------------------------------------------------------
# Pagination kit: paged windows, list + footer
# ---------------------------------------------------------------------------------------------

## Adopt [param result] as [param page]'s window — but only while it is still the window being
## asked for. Returns false when a newer jump moved the page on while this fetch was in flight:
## those rows belong to a page nobody is looking at any more, so they are dropped and the list keeps
## what it has. Paged fetches read their window into [param at] before awaiting, then check here.
func _land(page: ServicePage, at: int, result: Dictionary) -> bool:
	if page.offset != at:
		return false
	page.adopt(result)
	return true


## A paged list under [param title]: the list, then its footer, in one titled box added to [param
## parent]. The caller wires [param page]'s [signal ServicePage.load_requested] to the fetch that
## fills it.
func _paged_list(parent: Node, title: String, page: ServicePage, min_height: float = 160.0) -> ItemList:
	var list := _list(min_height)
	_paged_box(parent, title, page, list)
	return list


## [param body] under [param title] with its footer — the same box, for a list that is not an
## ItemList (a grid of tiles, a column of cards). Returns the box, so a caller that shows and hides
## it can keep hold of it.
func _paged_box(parent: Node, title: String, page: ServicePage, body: Control) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(body)
	box.add_child(_pager(page))
	var titled := _titled(title, box, true)
	parent.add_child(titled)
	return titled


## The footer under a paged list: first, previous, the window sentence, next, last. The buttons
## move the page — the panel has already wired [signal ServicePage.load_requested] to the fetch that
## fills the list — and the bar redraws itself whenever the page moves or a response lands. It stays
## hidden while there is only one window to stand on.
func _pager(page: ServicePage) -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	var first := _action_button(bar, tr("%%PG_FIRST"), func() -> void: page.first(), 46.0)
	var prev := _action_button(bar, tr("%%PG_PREV"), func() -> void: page.prev(), 46.0)
	var status := _label("", ServiceStyle.MUTED)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(status)
	var next := _action_button(bar, tr("%%PG_NEXT"), func() -> void: page.next(), 46.0)
	var last := _action_button(bar, tr("%%PG_LAST"), func() -> void: page.last(), 46.0)
	var sync := func() -> void:
		status.text = page.status_text()
		var back: bool = page.can_prev()
		var forward: bool = page.can_next()
		first.disabled = not back
		prev.disabled = not back
		next.disabled = not forward
		last.disabled = not forward
		bar.visible = page.pages() > 1
	page.load_requested.connect(sync)
	page.windowed.connect(sync)
	sync.call()
	return bar
