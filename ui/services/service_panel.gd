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


## A section wants the chart to name a place for it (a point of interest being created asks where it
## should stand). Relayed up through the shells that host it (see [method mount_segment]) so
## the console — which owns the chart — can act on it; this file never reaches for [StarMap].
## [param radius_m] is what the asker's radius field says (0 = a point): the marker's starting width.
signal placement_requested(radius_m: float)

## A section wants the chart to SHOW a place of the player's (the mission builder naming the point
## its clause points at). Relayed up through the shells that host it (see [method mount_segment]) so
## the console — which owns the chart — can open it there; this file never reaches for [StarMap].
##
## Nothing is armed and nothing comes back: this is a request to look, not a question to answer.
signal focus_poi_requested(poi_id: String)

## How the tablet should split the screen for the segment now on show: data on the left, this
## segment's actions in the right-hand column. Emitted when a segment is switched to, and once more
## after [method _build] has filled both halves.
signal pane_layout(has_main: bool, has_side: bool)

## A section wants another app open: [param id] (a [TerminalUI] APPS id) on its segment
## [param segment], and that segment's own tab [param sub] (-1: as it is). Relayed up through the
## shells that host it (see [method mount_segment]); the tablet does the opening, this file never
## reaches for another app. An inventory stack's "Put on sale" uses it to land on the market.
signal open_app_requested(id: String, segment: int, sub: int)

## Kept as the sections' unqualified vocabulary; all sourced from [ServiceStyle].
const ACCENT: Color = ServiceStyle.ACCENT
const DIM: Color = ServiceStyle.MUTED
const WARN: Color = ServiceStyle.WARN
const GOOD: Color = ServiceStyle.GOOD
const BG_COLOR: Color = ServiceStyle.BG
const FONT_PATH: String = "res://ui/Poppins-Regular.ttf"

## The app's right-hand action column, handed over by [TerminalUI] before the panel enters the tree
## (one column per app, so nothing is ever reparented). Panels build their action forms into it —
## one page per segment, through [method _side_page] — instead of stacking them under the lists.
var side_slot: VBoxContainer = null

## The tablet's chrome strip, above the two cards: the app bar and the segment tabs live there, so
## they stay on screen even when a form-only segment hands the whole content card to the column.
var tab_slot: VBoxContainer = null

## Focusable inputs registered here, so the screen contract can answer for all of them.
var _fields: Array[LineEdit] = []
var _text_areas: Array[TextEdit] = []
var _status: Label = null
var _status_panel: PanelContainer = null
var _status_timer: Timer = null
## The last segmented control built, so [method goto_segment] can switch it in code.
var _seg_bar: HBoxContainer = null
var _seg_holders: Array[ScrollContainer] = []
## The action-column page of each segment, index-aligned with the pages [method _segments_pages]
## returned — the half the tablet shows in its right-hand column.
var _side_pages: Array[VBoxContainer] = []
## Which segment is on show, so the layout can be re-read once the build filled both halves.
var _seg_index: int = 0
## Guards against overlapping refreshes (rapid section switches): a second refresh is skipped while
## one is in flight.
var _loading: bool = false
## Sections mounted into a segment by [method mount_segment]: {"index": int, "chrome": Control,
## "panel": ServicePanel}. Their chrome is shown only while their own segment is on show.
var _mounts: Array[Dictionary] = []
## The header [method _app_bar] built, so a composed app can set its section picker beside the title.
var _header_bar: HBoxContainer = null


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
	if side_slot == null:
		# Stood up outside the tablet (a test, a smoke scene): keep the column inside the panel so
		# it is neither parentless nor lost.
		side_slot = VBoxContainer.new()
		side_slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		side_slot.visible = false
		add_child(side_slot)
	if tab_slot == null:
		tab_slot = VBoxContainer.new()
		tab_slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		add_child(tab_slot)
	_build()
	# Both halves exist now: tell the tablet how to draw them (a form-only segment fills the width).
	pane_layout.emit(has_main_content(), has_side_content())


## Put a piece of chrome (the app bar, the segment tabs) in the tablet's strip above the cards, or
## in the panel itself when it is standing alone.
func add_chrome(child: Control) -> void:
	if tab_slot != null:
		tab_slot.add_child(child)
	else:
		add_child(child)


## Sections override this to lay themselves out. Called once, from _ready.
func _build() -> void:
	pass


## Reload the section's data from the services. Sections override.
func refresh() -> void:
	pass


## The chart named a place for whatever asked for it (see [signal placement_requested]). Sections
## that can take one override; the default is to have nothing to say about it.
##
## Answers whether the place was TAKEN, because the chart came from one form and has to be handed
## back to it: a no-answer lets the console try the next app rather than guessing which one asked.
func set_placed(_place: Dictionary) -> bool:
	return false


## The segment to come back to when a place was placed for this app: the one that holds the form
## that asked for it. The chart hands the place back and the player is taken straight to the form
## they were filling in, which is not always the segment the app opens on.
func placement_segment() -> int:
	return 0


# ---------------------------------------------------------------------------------------------
# Screen contract
# ---------------------------------------------------------------------------------------------

## True while one of our inputs — or a mounted section's — holds the keyboard. The owning console
## relays this so the game stops acting on what is being typed.
func is_typing() -> bool:
	for field: LineEdit in _fields:
		if field != null and field.has_focus():
			return true
	for area: TextEdit in _text_areas:
		if area != null and area.has_focus():
			return true
	for mount: Dictionary in _mounts:
		var panel: ServicePanel = mount.get("panel")
		if panel != null and panel.is_typing():
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
	for mount: Dictionary in _mounts:
		var panel: ServicePanel = mount.get("panel")
		if panel != null:
			panel.release_fields()


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
	ServiceStyle.ares_of(label, ServiceStyle.SIZE_HEADING)
	return label


## A group caption (the mock-up's panel head): small, spaced capitals in the second text colour.
func _subheading(text: String) -> Label:
	var label := Label.new()
	label.text = text.to_upper()
	label.add_theme_color_override("font_color", ServiceStyle.TEXT_2)
	ServiceStyle.font_of(label, ServiceStyle.SIZE_SMALL, true)
	var pad := StyleBoxEmpty.new()
	pad.content_margin_top = 6.0
	pad.content_margin_bottom = 6.0
	label.add_theme_stylebox_override("normal", pad)
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
	field.custom_minimum_size = Vector2(min_width, 48)
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
		button.custom_minimum_size = Vector2(min_width, 48)
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


## [method _action_button] as the form's call to action: the amber primary button.
func _primary_button(parent: Node, text: String, handler: Callable, min_width: float = 0.0) -> Button:
	var button := _action_button(parent, text, handler, min_width)
	ServiceStyle.apply_button(button, true)
	return button


## An OptionButton whose labels are localized and whose item metadata keeps the raw API value.
## [param entries] is an array of `[value, translation key]` pairs.
func _option_enum(entries: Array, min_width: float = 160.0) -> OptionButton:
	var option := OptionButton.new()
	for entry: Array in entries:
		option.add_item(tr(str(entry[1])))
		option.set_item_metadata(option.item_count - 1, str(entry[0]))
	option.custom_minimum_size = Vector2(min_width, 48)
	ServiceStyle.apply_option(option)
	return option


## The raw API value behind an [OptionButton]'s selected item (its metadata), or "".
static func _enum_value(option: OptionButton) -> String:
	if option.selected < 0 or option.selected >= option.item_count:
		return ""
	return str(option.get_item_metadata(option.selected))


## Select the row whose raw value is [param value], if the list has one. A filter that opens on
## "everything" shows the player a wall of what is over; a filter that opens on what is live is the
## list they came for.
func _select_enum_value(option: OptionButton, value: String) -> void:
	for i: int in range(option.item_count):
		if str(option.get_item_metadata(i)) == value:
			option.select(i)
			return


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

## An app's header (the mock-up's `.hdr`): its title in the ARES face, then room for a segmented
## control (a composed app's sections, see [method _mount_bar]), a spacer, and the refresh button at
## the far end. Action buttons the caller adds after this returns land after the refresh button.
## No back button: the bottom bar's tabs are the way home (playtest 2026-11-07, one in every app).
##
## [param _icon_kind] is kept for the callers; the header shows no glyph any more (the bottom bar names
## the app). [param with_refresh] = false for an app whose own button already reloads it.
func _app_bar(title: String, _icon_kind: ServiceAppIcon.Kind, with_refresh: bool = true) -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 32)
	bar.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	bar.custom_minimum_size = Vector2(0, 64)
	bar.set_meta(APP_BAR_META, true)
	var label := ServiceStyle.ares_label(title, ServiceStyle.TEXT, ServiceStyle.SIZE_TITLE)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar.add_child(label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.name = "Spacer"
	bar.add_child(spacer)
	if with_refresh:
		bar.add_child(_icon_button(ServiceAppIcon.Kind.REFRESH, tr("%%SVC_ACT_REFRESH"),
				func() -> void: refresh()))
	_header_bar = bar
	return bar


## A square icon-only button (the mock-up's `.icon-btn`), its words in the tooltip.
func _icon_button(kind: ServiceAppIcon.Kind, tip: String, handler: Callable) -> Button:
	var button := Button.new()
	button.custom_minimum_size = Vector2(52, 52)
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.tooltip_text = tip
	ServiceStyle.apply_button(button)
	var icon := ServiceAppIcon.new()
	icon.kind = kind
	icon.colour = ServiceStyle.TEXT_2
	icon.custom_minimum_size = Vector2.ZERO  # its default 44 px would push it off the button's centre
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 14.0
	icon.offset_top = 14.0
	icon.offset_right = -14.0
	icon.offset_bottom = -14.0
	button.add_child(icon)
	button.pressed.connect(handler)
	return button


## Put [param control] in the header just before its spacer: what sits next to the title.
func _header_insert(control: Control) -> bool:
	if _header_bar == null:
		return false
	var spacer: Node = _header_bar.get_node_or_null("Spacer")
	_header_bar.add_child(control)
	if spacer != null:
		_header_bar.move_child(control, spacer.get_index())
	return true


## Put [param control] in the header after its spacer, before the refresh button: the right-hand end
## (the economy's balance).
func _header_append(control: Control) -> bool:
	if _header_bar == null:
		return false
	var spacer: Node = _header_bar.get_node_or_null("Spacer")
	_header_bar.add_child(control)
	if spacer != null:
		_header_bar.move_child(control, spacer.get_index() + 1)
	return true


## A segmented control + one scrollable page per segment. Adds the bar and the pages to [code]self[/code]
## and returns the page boxes, in order, for the caller to fill. Pages other than the first start
## hidden. The last built set is remembered so [method goto_segment] can switch to a page in code.
##
## The bar is drawn as the mock-up's sub-tabs: words over an amber underline, along a hairline strip.
##
## Every segment gets a second, parallel page in [member side_slot] — its action half (see
## [method _side_page]) — and switching a segment switches both halves and tells the tablet how to
## split the screen between them.
func _segments_pages(labels: PackedStringArray) -> Array[VBoxContainer]:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 36)
	bar.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	bar.set_meta(SUBTABS_META, true)
	var strip := PanelContainer.new()
	var rule := ServiceStyle.underline(ServiceStyle.LINE, 1)
	rule.border_width_top = 1
	strip.add_theme_stylebox_override("panel", rule)
	strip.add_child(bar)
	add_chrome(strip)

	var pages: Array[VBoxContainer] = []
	var holders: Array[ScrollContainer] = []
	_side_pages.clear()
	for _i: int in range(labels.size()):
		var page := VBoxContainer.new()
		page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		page.add_theme_constant_override("separation", 16)
		var scroll := ScrollContainer.new()
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		# Each page is a panel of its own by default; a page that lays out its own panels drops it
		# ([method _frameless]).
		scroll.add_theme_stylebox_override("panel", ServiceStyle.flat(ServiceStyle.PANEL,
				ServiceStyle.RADIUS_PANEL, ServiceStyle.LINE, 1, 28.0, 26.0))
		scroll.add_child(page)
		add_child(scroll)
		pages.append(page)
		holders.append(scroll)

		var side := VBoxContainer.new()
		side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		side.size_flags_vertical = Control.SIZE_EXPAND_FILL
		side.add_theme_constant_override("separation", 16)
		side_slot.add_child(side)
		_side_pages.append(side)

	for i: int in range(labels.size()):
		var tab := Button.new()
		tab.text = labels[i]
		ServiceStyle.apply_subtab(tab, i == 0)
		var index: int = i
		tab.pressed.connect(func() -> void: _show_segment(bar, holders, index))
		bar.add_child(tab)

	_seg_bar = bar
	_seg_holders = holders
	_show_segment(bar, holders, 0)
	return pages


## The bar and the action column of a COMPOSED app, with no content pages at all: each segment
## holds a whole section (see [method mount_segment]), and a section already carries its own card,
## its own scrolling and its own layout. Wrapping it in this shell's page would put a second set of
## margins around content that has some — and a ScrollContainer inside a ScrollContainer is how a
## panel ends up being handed no height at all.
##
## The bar is the mock-up's segmented control, set in the app's header beside its title when the
## shell built one ([method _app_bar]); the sections' own titles then stay hidden.
func _mount_bar(labels: PackedStringArray) -> void:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 4)
	var groove := PanelContainer.new()
	groove.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ServiceStyle.apply_segment_groove(groove)
	groove.add_child(bar)
	if not _header_insert(groove):
		add_chrome(groove)

	var holders: Array[ScrollContainer] = []
	_side_pages.clear()
	for _i: int in range(labels.size()):
		var side := VBoxContainer.new()
		side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		side.size_flags_vertical = Control.SIZE_EXPAND_FILL
		side.add_theme_constant_override("separation", 16)
		side_slot.add_child(side)
		_side_pages.append(side)

	for i: int in range(labels.size()):
		var tab := Button.new()
		tab.text = labels[i]
		ServiceStyle.apply_segment(tab, i == 0)
		var index: int = i
		tab.pressed.connect(func() -> void: _show_segment(bar, holders, index))
		bar.add_child(tab)

	_seg_bar = bar
	_seg_holders = holders
	_seg_index = 0
	pane_layout.emit(has_main_content(), has_side_content())


## The action-column page of the [param index]-th segment: forms, filters and the buttons that act
## on what the left half is showing. Callers fill it right after [method _segments_pages] returns.
func _side_page(index: int) -> VBoxContainer:
	if index < 0 or index >= _side_pages.size():
		return null
	return _side_pages[index]


## Hide the [param index]-th segment's tab: the segment stays built (others are addressed by index)
## but cannot be reached from the bar any more.
func hide_segment_tab(index: int) -> void:
	if _seg_bar != null and index >= 0 and index < _seg_bar.get_child_count():
		(_seg_bar.get_child(index) as Control).visible = false


## Switch to the [param index]-th segment built by the last [method _segments_pages] call.
func goto_segment(index: int) -> void:
	# The bar's tabs, not the pages: a composed app has a tab per section and no pages of its own.
	if _seg_bar != null and index >= 0 and index < _seg_bar.get_child_count():
		_show_segment(_seg_bar, _seg_holders, index)


## Mount a section script as the segment [param index] of this composed app: the section gets its own
## chrome slot (its app bar and its own tabs draw there, hidden while another segment is on show)
## and the segment's action column. A composed app is thus a thin shell whose segments each hold a
## whole section, rather than a rewrite of every section's layout.
##
## The section becomes a DIRECT child of [code]self[/code] — never nested in a page of this shell's
## own. It is laid out by the same VBoxContainer the sections of a plain app would be, which is the
## only arrangement the card is known to hand a real height to.
## Marks an app's title bar (_app_bar): a mounted section's goes up above the shell's section bar.
const APP_BAR_META := &"app_bar"
## Marks a bar drawn as sub-tabs (_segments_pages) rather than as a segmented control (_mount_bar).
const SUBTABS_META := &"subtabs"
## A list's empty state ([method _empty_for]), kept on the list so the static [method _fill_list]
## can switch between them.
const EMPTY_META := &"empty_state"


func mount_segment(index: int, script_path: String) -> ServicePanel:
	var chrome := VBoxContainer.new()
	chrome.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chrome.visible = index == _seg_index
	add_chrome(chrome)
	var script: GDScript = load(script_path)
	var panel: ServicePanel = script.new()
	panel.tab_slot = chrome
	var side := _side_page(index)
	if side != null:
		panel.side_slot = side
	# Sections stand alone (a test, a smoke scene) unless a tablet hosts them; the shell is that host
	# and asks no more of them than the tablet did. Visible only while their own segment is on show:
	# the shell toggles both the chrome and the section, never just the chrome.
	panel.visible = index == _seg_index
	_mounts.append({"index": index, "chrome": chrome, "panel": panel})
	add_child(panel)
	# The section's title above the shell's bar of sections, as every app's title tops its tabs
	# (playtest 2026-11-07: "Banque" sat under "Banque | Marché"). It follows its section's visibility.
	for child: Node in chrome.get_children():
		if child.has_meta(APP_BAR_META) and _header_bar != null:
			# The shell's own header names the app and carries the section picker: the section's
			# title would only say it twice.
			(child as Control).visible = false
			child.remove_meta(APP_BAR_META)
			continue
		if child.has_meta(APP_BAR_META):
			var host: Node = tab_slot if tab_slot != null else self
			child.reparent(host)
			host.move_child(child, 0)
			(child as Control).visible = chrome.visible
			_mounts.back()["title"] = child
	# A form-only segment of the section asks for the column: the shell relays it so the tablet splits
	# the way the section on show needs, not the way the shell itself would.
	panel.pane_layout.connect(_relay_pane.bind(panel))
	# A section may ask the chart for a place; the shell carries it up, never to the chart itself.
	panel.placement_requested.connect(placement_requested.emit)
	# And a section may ask the chart to show one; same way round.
	panel.focus_poi_requested.connect(focus_poi_requested.emit)
	# And a section may ask for another app; the tablet opens it.
	panel.open_app_requested.connect(open_app_requested.emit)
	return panel


## The mounted section whose segment is on show, or null.
func mounted_section() -> ServicePanel:
	for mount: Dictionary in _mounts:
		if int(mount.get("index", -1)) == _seg_index:
			return mount.get("panel") as ServicePanel
	return null


func _relay_pane(has_main: bool, has_side: bool, panel: ServicePanel) -> void:
	if mounted_section() == panel:
		pane_layout.emit(has_main, has_side)


func _show_segment(bar: HBoxContainer, holders: Array[ScrollContainer], index: int) -> void:
	var subtabs: bool = bar.has_meta(SUBTABS_META)
	for i: int in range(bar.get_child_count()):
		if subtabs:
			ServiceStyle.apply_subtab(bar.get_child(i) as Button, i == index)
		else:
			ServiceStyle.apply_segment(bar.get_child(i) as Button, i == index)
	for i: int in range(holders.size()):
		holders[i].visible = i == index
	for i: int in range(_side_pages.size()):
		(_side_pages[i] as VBoxContainer).visible = i == index
	for mount: Dictionary in _mounts:
		var mounted_index: int = int(mount.get("index", -1))
		var chrome: Control = mount.get("chrome")
		if chrome != null:
			chrome.visible = mounted_index == index
		var title: Variant = mount.get("title")
		if title is Control:
			(title as Control).visible = mounted_index == index
		# The section itself is drawn in the card, and must follow its chrome — a section that is
		# hidden while its chrome shows is a title bar over nothing.
		var mounted: ServicePanel = mount.get("panel") as ServicePanel
		if mounted != null:
			mounted.visible = mounted_index == index
	_seg_index = index
	var section := mounted_section()
	if section != null:
		# The section on show decides the split: its form-only segment is the whole card.
		pane_layout.emit(section.has_main_content(), section.has_side_content())
	else:
		pane_layout.emit(has_main_content(), has_side_content())


## Whether the segment on show has anything to draw on the left. A segment that is nothing but a
## form has moved entirely into the column, and the tablet gives the column the whole width.
##
## A COMPOSED app has no holders of its own to ask — its segments hold whole sections, and the
## section on show is the only one that knows whether its card half is empty.
func has_main_content() -> bool:
	var mounted := mounted_section()
	if mounted != null:
		return mounted.has_main_content()
	if _seg_index < 0 or _seg_index >= _seg_holders.size():
		return true
	var holder: ScrollContainer = _seg_holders[_seg_index]
	if holder.get_child_count() == 0:
		return true
	return (holder.get_child(0) as Node).get_child_count() > 0


## Whether the segment on show put anything in the right-hand column.
func has_side_content() -> bool:
	var mounted := mounted_section()
	if mounted != null:
		return mounted.has_side_content()
	if _seg_index < 0 or _seg_index >= _side_pages.size():
		return false
	return not (_side_pages[_seg_index] as VBoxContainer).get_children().is_empty()


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


# ---------------------------------------------------------------------------------------------
# A.R.E.S. OS kit: stat cards, empty states, progress, tags (the 2026-11 mock-up)
# ---------------------------------------------------------------------------------------------

## The dashed frame of an empty state: Godot's StyleBoxFlat has no dashed edge, so it is drawn here.
class DashedFrame extends PanelContainer:
	const DASH: float = 7.0
	const RADIUS: float = 14.0

	func _draw() -> void:
		var r: float = minf(RADIUS, minf(size.x, size.y) * 0.5)
		var colour: Color = ServiceStyle.LINE_DASH
		var w := size.x
		var h := size.y
		draw_dashed_line(Vector2(r, 0.5), Vector2(w - r, 0.5), colour, 1.0, DASH)
		draw_dashed_line(Vector2(r, h - 0.5), Vector2(w - r, h - 0.5), colour, 1.0, DASH)
		draw_dashed_line(Vector2(0.5, r), Vector2(0.5, h - r), colour, 1.0, DASH)
		draw_dashed_line(Vector2(w - 0.5, r), Vector2(w - 0.5, h - r), colour, 1.0, DASH)
		draw_arc(Vector2(r, r), r - 0.5, PI, PI * 1.5, 8, colour, 1.0, true)
		draw_arc(Vector2(w - r, r), r - 0.5, PI * 1.5, TAU, 8, colour, 1.0, true)
		draw_arc(Vector2(w - r, h - r), r - 0.5, 0.0, PI * 0.5, 8, colour, 1.0, true)
		draw_arc(Vector2(r, h - r), r - 0.5, PI * 0.5, PI, 8, colour, 1.0, true)


## An empty state (the mock-up's `.empty`): a dashed frame around a short title, a sentence saying
## what will show up here, and — when there is somewhere to go about it — one button that goes there.
## [param action] is the button's words, [param handler] what it does; "" / an invalid Callable for none.
static func _empty_state(title: String, text: String, action: String = "",
		handler: Callable = Callable(), primary: bool = true) -> Control:
	var frame := DashedFrame.new()
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frame.add_theme_stylebox_override("panel", ServiceStyle.flat(Color.TRANSPARENT, 0,
			Color.TRANSPARENT, 0, 32.0, 32.0))
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 12)
	frame.add_child(box)
	if title != "":
		var heading := ServiceStyle.label(title, ServiceStyle.TEXT, 17, true)
		heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(heading)
		frame.set_meta(&"title", heading)
	if text != "":
		var line := ServiceStyle.label(text, ServiceStyle.MUTED, ServiceStyle.SIZE_SMALL)
		line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		line.custom_minimum_size = Vector2(320, 0)
		box.add_child(line)
	if action != "" and handler.is_valid():
		var button := Button.new()
		button.text = action
		button.custom_minimum_size = Vector2(0, 48)
		ServiceStyle.apply_button(button, primary)
		button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		button.pressed.connect(handler)
		box.add_child(button)
	return frame


## A stat card (the mock-up's `.card`): a muted caption, a value, an optional muted line under it.
## Returns the card; the value label is its meta "value" for the caller to update.
static func _stat_card(caption: String, value: String, sub: String = "",
		value_colour: Color = ServiceStyle.TEXT, value_size: int = 22) -> PanelContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ServiceStyle.apply_card(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	card.add_child(box)
	box.add_child(ServiceStyle.label(caption, ServiceStyle.MUTED, ServiceStyle.SIZE_CAPTION))
	var shown := ServiceStyle.label(value, value_colour, value_size, true)
	shown.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(shown)
	card.set_meta("value", shown)
	if sub != "":
		var line := ServiceStyle.label(sub, ServiceStyle.MUTED, ServiceStyle.SIZE_CAPTION)
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(line)
	return card


## A thin progress track, [param ratio] of it filled amber (0..1).
static func _progress_bar(ratio: float, height: float = 6.0) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = clampf(ratio, 0.0, 1.0)
	bar.custom_minimum_size = Vector2(0, height)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var radius := int(height * 0.5)
	bar.add_theme_stylebox_override("background", ServiceStyle.flat(ServiceStyle.TRACK, radius,
			Color.TRANSPARENT, 0))
	bar.add_theme_stylebox_override("fill", ServiceStyle.flat(ServiceStyle.ACCENT, radius,
			Color.TRANSPARENT, 0))
	return bar


## A small spaced-capitals tag in the info blue (the mock-up's `.tag`: a mission's type).
static func _tag(text: String, colour: Color = ServiceStyle.INFO) -> Label:
	return ServiceStyle.label(text.to_upper(), colour, 12, true)


## A titled panel of the mock-up (`.panel` + `.panel-head`): the head (caption, count, then room for
## a link or filters after its spacer) over a body the caller fills. [member body] is where content
## goes; [member head] takes extra controls (they land after the spacer); [member count] is the
## figure beside the caption, "" to leave it blank.
class Card extends PanelContainer:
	var head: HBoxContainer
	var body: VBoxContainer
	var count: Label
	var caption: Label

	## Set the figure beside the caption ("" hides it).
	func set_count(value: String) -> void:
		count.text = value
		count.visible = value != ""


## A panel (see [Card]) titled [param title] ("" for none: no head at all), its count [param count].
## [param pad] is its inner margin (px); [param expand] whether it takes the room it is given.
static func _panel(title: String = "", count: String = "", pad: float = 26.0, expand: bool = true) -> Card:
	var card := Card.new()
	card.add_theme_stylebox_override("panel",
			ServiceStyle.flat(ServiceStyle.PANEL, ServiceStyle.RADIUS_PANEL, ServiceStyle.LINE, 1, pad, pad))
	if expand:
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 18)
	card.add_child(column)
	card.head = HBoxContainer.new()
	card.head.add_theme_constant_override("separation", 12)
	card.caption = ServiceStyle.label(title.to_upper(), ServiceStyle.TEXT_2, ServiceStyle.SIZE_SMALL, true)
	card.caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	card.head.add_child(card.caption)
	card.count = ServiceStyle.label(count, ServiceStyle.MUTED, ServiceStyle.SIZE_SMALL)
	card.count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	card.count.visible = count != ""
	card.head.add_child(card.count)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.head.add_child(spacer)
	card.head.visible = title != ""
	column.add_child(card.head)
	card.body = VBoxContainer.new()
	card.body.add_theme_constant_override("separation", 16)
	card.body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(card.body)
	return card


## A row of panels side by side (the mock-up's `.content`): add [method _panel]s to it. A fixed-width
## panel gets `custom_minimum_size.x` and no SIZE_EXPAND; the other one takes the rest.
static func _columns(separation: int = 24) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", separation)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return row


## A panel of fixed width [param width] px (the mock-up's 380 / 420 / 480 px side panels).
static func _fixed(card: Control, width: float) -> Control:
	card.custom_minimum_size.x = width
	card.size_flags_horizontal = Control.SIZE_FILL
	return card


## Draw a page without the panel its segment gives it by default: for a page that lays out panels of
## its own (two columns, a list beside a detail). [param page] is a page [method _segments_pages]
## returned. The page also stops scrolling as a whole: its panels scroll inside themselves.
static func _frameless(page: VBoxContainer) -> void:
	var scroll := page.get_parent() as ScrollContainer
	if scroll == null:
		return
	scroll.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL


## A scroll box for a panel's list (rows longer than the panel scroll inside it, not the page).
static func _scroll(content: Control) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	return scroll


## A big title in the ARES face (the mock-up's `.title-lg`).
static func _title_lg(text: String, size: int = 30) -> Label:
	var title := ServiceStyle.ares_label(text, ServiceStyle.TEXT, size)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return title


## A big figure (the mock-up's `.big`, a balance, a score): the ARES face, amber by default.
static func _big(text: String, colour: Color = ServiceStyle.ACCENT, size: int = 40) -> Label:
	return ServiceStyle.ares_label(text, colour, size)


## A small muted line under a field (the mock-up's `.hint`).
static func _hint(text: String) -> Label:
	var hint := ServiceStyle.label(text, ServiceStyle.HINT, ServiceStyle.SIZE_CAPTION)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return hint


## A square badge with a short text in it (the mock-up's `.thumb`: a good's code, a mission's step).
static func _thumb(text: String, side: float = 48.0) -> PanelContainer:
	var thumb := PanelContainer.new()
	thumb.custom_minimum_size = Vector2(side, side)
	thumb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ServiceStyle.apply_thumb(thumb)
	var label := ServiceStyle.label(text, ServiceStyle.ACCENT, ServiceStyle.SIZE_CAPTION, true)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumb.add_child(label)
	return thumb


## A labelled form field (the mock-up's `.field`): the label, the control, and an optional hint.
static func _form_field(caption: String, control: Control, hint: String = "") -> VBoxContainer:
	var field := VBoxContainer.new()
	field.add_theme_constant_override("separation", 8)
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if caption != "":
		field.add_child(ServiceStyle.label(caption, ServiceStyle.TEXT_2, ServiceStyle.SIZE_SMALL, true))
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.add_child(control)
	if hint != "":
		field.add_child(_hint(hint))
	return field


## A field with its unit glued on its right (the mock-up's `.input-group`: "0 | cr").
static func _suffix_field(field: LineEdit, suffix: String) -> PanelContainer:
	var group := PanelContainer.new()
	group.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	group.add_theme_stylebox_override("panel",
			ServiceStyle.flat(ServiceStyle.FIELD_BG, ServiceStyle.RADIUS_SMALL, ServiceStyle.LINE_2, 1))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	group.add_child(row)
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for state: String in ["normal", "focus", "read_only"]:
		field.add_theme_stylebox_override(state, ServiceStyle.flat(Color.TRANSPARENT, 0, Color.TRANSPARENT, 0, 16.0, 10.0))
	row.add_child(field)
	var unit := PanelContainer.new()
	var edge := StyleBoxFlat.new()
	edge.bg_color = Color.TRANSPARENT
	edge.border_width_left = 1
	edge.border_color = ServiceStyle.LINE_2
	edge.content_margin_left = 16.0
	edge.content_margin_right = 16.0
	unit.add_theme_stylebox_override("panel", edge)
	var unit_label := ServiceStyle.label(suffix, ServiceStyle.MUTED, ServiceStyle.SIZE_SMALL)
	unit_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	unit.add_child(unit_label)
	row.add_child(unit)
	return group


## Two fields side by side (the mock-up's `.row`): each takes half.
static func _field_row(controls: Array, separation: int = 18) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", separation)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for control: Control in controls:
		control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		control.size_flags_stretch_ratio = 1.0
		row.add_child(control)
	return row


## A set of choice chips (the mock-up's `.choice`): [param entries] is `[[id, label], ...]`, the chip
## of [param current] lit; picking one lights it and calls [param on_pick] with its id. The bar's meta
## "current" holds the id picked.
static func _choice_bar(entries: Array, current: String, on_pick: Callable) -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	bar.set_meta(&"current", current)
	for entry: Array in entries:
		var chip := Button.new()
		chip.text = str(entry[1])
		chip.set_meta(&"id", str(entry[0]))
		chip.focus_mode = Control.FOCUS_NONE
		ServiceStyle.apply_choice(chip, str(entry[0]) == current)
		chip.pressed.connect(func() -> void:
			_pick_choice(bar, str(entry[0]))
			if on_pick.is_valid():
				on_pick.call(str(entry[0])))
		bar.add_child(chip)
	return bar


## Light chip [param id] of a [method _choice_bar] (no callback).
static func _pick_choice(bar: HBoxContainer, id: String) -> void:
	bar.set_meta(&"current", id)
	for chip: Node in bar.get_children():
		if chip is Button and chip.has_meta(&"id"):
			ServiceStyle.apply_choice(chip as Button, str(chip.get_meta(&"id")) == id)


## A two-column key / value list (the mock-up's `.kv`: a summary). [param pairs] is
## `[[caption, value], ...]`; the value labels are returned in the grid's meta "values", in order, for
## the caller to update.
static func _kv_grid(pairs: Array, key_width: float = 170.0) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 14)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var values: Array[Label] = []
	for pair: Array in pairs:
		var key := ServiceStyle.label(str(pair[0]), ServiceStyle.MUTED, ServiceStyle.SIZE_BODY)
		key.custom_minimum_size.x = key_width
		grid.add_child(key)
		var value := ServiceStyle.label(str(pair[1]), ServiceStyle.TEXT, ServiceStyle.SIZE_BODY)
		value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		value.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		grid.add_child(value)
		values.append(value)
	grid.set_meta(&"values", values)
	return grid


## The action bar at the foot of a form (the mock-up's `.actions`): a hairline, then the buttons the
## caller adds (put a spacer first to push them right — [method _spacer]).
static func _actions_bar() -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 12)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return bar


## A control that takes the free room of a row (pushes what follows to the end).
static func _spacer() -> Control:
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return spacer


## A rich row (the mock-up's `.item`): a badge, a name over a muted line, a value at the end. A button:
## [param row] keys — `thumb` (badge text, "" for none), `name`, `sub`, `value`, `value_colour`,
## `mono` (the value in the ARES face), `selected`.
static func _item_row(row: Dictionary) -> Button:
	var tile := Button.new()
	tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tile.custom_minimum_size = Vector2(0, 76)
	tile.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	tile.focus_mode = Control.FOCUS_NONE
	ServiceStyle.apply_tile(tile, bool(row.get("selected", false)))
	var line := HBoxContainer.new()
	line.set_anchors_preset(Control.PRESET_FULL_RECT)
	line.offset_left = 16.0
	line.offset_right = -18.0
	line.add_theme_constant_override("separation", 16)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(line)
	var badge: String = str(row.get("thumb", ""))
	if badge != "":
		line.add_child(_thumb(badge))
	var texts := VBoxContainer.new()
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.alignment = BoxContainer.ALIGNMENT_CENTER
	texts.add_theme_constant_override("separation", 3)
	texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name := ServiceStyle.label(str(row.get("name", "—")), ServiceStyle.TEXT, 17, true)
	name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.add_child(name)
	var sub: String = str(row.get("sub", ""))
	if sub != "":
		var sub_label := ServiceStyle.label(sub, ServiceStyle.MUTED, ServiceStyle.SIZE_CAPTION)
		sub_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		sub_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		texts.add_child(sub_label)
	line.add_child(texts)
	var value: String = str(row.get("value", ""))
	if value != "":
		var colour: Color = row.get("value_colour", ServiceStyle.TEXT)
		var value_label: Label = ServiceStyle.ares_label(value, colour, 18) if bool(row.get("mono", false)) \
				else ServiceStyle.label(value, colour, ServiceStyle.SIZE_BODY, true)
		value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		value_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_child(value_label)
	return tile


## A list of rich rows ([method _item_row]) with one selected at a time: the mock-up's `.list`, where an
## [ItemList] can only show one line of text. [signal row_selected] gives the picked row's `meta`.
class RowList extends VBoxContainer:
	signal row_selected(meta: Variant)
	var _rows: Array = []
	var _selected: int = -1

	func _init() -> void:
		add_theme_constant_override("separation", 10)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL

	## Replace the rows. Each is a [method ServicePanel._item_row] dictionary plus `meta` (what
	## [signal row_selected] hands back). The selection is kept on the row whose meta is the same.
	func set_rows(rows: Array) -> void:
		var was: Variant = selected_meta()
		for child: Node in get_children():
			remove_child(child)
			child.queue_free()
		_rows = rows
		_selected = -1
		for i: int in range(rows.size()):
			if was != null and rows[i].get("meta") == was:
				_selected = i
			_add(i)

	## Add a row built by the caller (a mission card…): [param tile] is a [Button] it styled with
	## [method ServiceStyle.apply_tile]; [param meta] what selecting it hands back.
	func add_custom(tile: Button, meta: Variant) -> void:
		_rows.append({"meta": meta, "custom": true})
		var index: int = _rows.size() - 1
		tile.pressed.connect(func() -> void: select(index))
		add_child(tile)

	func _add(i: int) -> void:
		var row: Dictionary = _rows[i].duplicate()
		row["selected"] = i == _selected
		var tile := ServicePanel._item_row(row)
		tile.pressed.connect(func() -> void: select(i))
		add_child(tile)

	## Select row [param index] (lit, and announced).
	func select(index: int) -> void:
		if index < 0 or index >= _rows.size():
			return
		_selected = index
		for i: int in range(get_child_count()):
			var tile := get_child(i) as Button
			if tile != null:
				ServiceStyle.apply_tile(tile, i == index)
		row_selected.emit(_rows[index].get("meta"))

	## Select the first row whose meta satisfies [param test] (a Callable(meta) -> bool).
	func select_where(test: Callable) -> bool:
		for i: int in range(_rows.size()):
			if test.call(_rows[i].get("meta")):
				select(i)
				return true
		return false

	func selected_meta() -> Variant:
		return _rows[_selected].get("meta") if _selected >= 0 and _selected < _rows.size() else null

	func row_count() -> int:
		return _rows.size()


## Replace a list's rows with [param lines] (metadata kept alongside for selection handling).
##
## A list given an empty state ([method _empty_for]) shows it instead of itself while no row carries
## metadata — the lines are then the panel's "nothing here" (or its error), and become the state's title.
static func _fill_list(list: ItemList, lines: PackedStringArray, metadata: Array = []) -> void:
	list.clear()
	for i: int in range(lines.size()):
		list.add_item(lines[i])
		if i < metadata.size():
			list.set_item_metadata(i, metadata[i])
	if list.has_meta(EMPTY_META):
		var frame: Control = list.get_meta(EMPTY_META)
		var nothing: bool = metadata.is_empty()
		frame.visible = nothing
		list.visible = not nothing
		var title: Label = frame.get_meta(&"title")
		title.text = "\n".join(lines)


## Give [param list] an empty state (the mock-up's dashed `.empty`), set just after it: shown instead
## of the list while it has no rows, titled with the panel's own "nothing here" line, explained by
## [param text], and — when [param action] is not "" — with one button doing [param handler].
## The list must already be in its parent (as [method _paged_list] leaves it).
func _empty_for(list: ItemList, text: String = "", action: String = "",
		handler: Callable = Callable()) -> void:
	var frame := _empty_state(" ", text, action, handler)
	frame.custom_minimum_size = Vector2(0, list.custom_minimum_size.y)
	frame.visible = false
	list.add_sibling(frame)
	list.set_meta(EMPTY_META, frame)


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
