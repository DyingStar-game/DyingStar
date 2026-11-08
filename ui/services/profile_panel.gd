extends ServicePanel

## App « Identité » : the caller's profile, an edit form, the reputation/sanctions journal, and the
## activity feed. Reads GET /api/me (+ /reputation, /sanctions, /activity) and writes PATCH /api/me.
##
## Laid out as the A.R.E.S. OS mock-up (2026-11): every tab is two columns of panels in the card —
## the identity card beside the biography and the roleplay sheet, the public profile beside the
## roleplay form, the score and sanctions beside the history. No tab uses the action column.

## The edit form's segment, where the empty biography and roleplay sheet send the player.
const EDIT_SEGMENT: int = 1

var _avatar_label: Label
var _hero_name: Label
var _presence_box: PanelContainer
var _presence_light: Panel
var _presence_label: Label
var _reputation_card: PanelContainer
var _corporation_card: PanelContainer
var _bio_display: RichTextLabel
var _bio_empty: Control
var _rp_display: RichTextLabel
var _rp_empty: Control
var _id_value: Label
var _role_value: Label
var _name_field: LineEdit
var _bio_field: TextEdit
var _rp_name_field: LineEdit
var _rp_alignment_field: LineEdit
var _rp_story_field: TextEdit
var _rp_original: Dictionary = {}  # last loaded rpSheet, to patch only when edited
## The last loaded display name and biography: what Cancel puts back in the form.
var _loaded_name: String = ""
var _loaded_bio: String = ""
var _reputation_label: Label
var _events: ItemList
var _events_card: Card
var _page_events: ServicePage
var _sanctions_box: VBoxContainer
var _activity: ItemList
var _activity_card: Card
var _page_activity: ServicePage


func _build() -> void:
	var bar := _app_bar(tr("%%SVC_APP_IDENTITY"), ServiceAppIcon.Kind.IDENTITY)
	add_chrome(bar)

	var pages := _segments_pages(PackedStringArray([
			tr("%%SVC_TAB_PROFILE"), tr("%%SVC_TAB_EDIT"),
			tr("%%SVC_TAB_REPUTATION"), tr("%%SVC_TAB_ACTIVITY")]))
	_build_profil_page(pages[0])
	_build_edit_page(pages[EDIT_SEGMENT])
	_build_reputation_page(pages[2])
	_build_activity_page(pages[3])
	add_chrome(_status_line())


# ---------------------------------------------------------------------------------------------
# Profil — identity card | biography + roleplay sheet
# ---------------------------------------------------------------------------------------------

func _build_profil_page(page: VBoxContainer) -> void:
	_frameless(page)
	var columns := _columns()
	page.add_child(columns)
	columns.add_child(_fixed(_identity_card(), 400.0))

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 24)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_child(right)

	var bio := _panel(tr("%%SVC_LBL_BIOGRAPHY"))
	_bio_display = _rich_text(60.0)
	_bio_display.visible = false
	bio.body.add_child(_scroll(_bio_display))
	_bio_empty = _empty_state(tr("%%SVC_PROFILE_NO_BIO"), tr("%%SVC_PROFILE_NO_BIO_TEXT"),
			tr("%%SVC_ACT_WRITE_BIO"), func() -> void: goto_segment(EDIT_SEGMENT), false)
	bio.body.add_child(_bio_empty)
	right.add_child(bio)

	var rp := _panel(tr("%%SVC_LBL_RP_SHEET"))
	_rp_display = _rich_text(90.0)
	_rp_display.visible = false
	rp.body.add_child(_scroll(_rp_display))
	_rp_empty = _empty_state(tr("%%SVC_MSG_NO_RP"), tr("%%SVC_PROFILE_NO_RP_TEXT"),
			tr("%%SVC_ACT_CREATE_RP"), func() -> void: goto_segment(EDIT_SEGMENT), false)
	rp.body.add_child(_rp_empty)
	right.add_child(rp)


## The left panel: the portrait, the name and presence, reputation and corporation, then the id and
## the role at its foot.
func _identity_card() -> Control:
	var card := _panel("", "", 30.0)
	var body := card.body
	body.add_theme_constant_override("separation", 16)

	var avatar := _avatar(120.0)
	avatar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	body.add_child(avatar)
	_hero_name = _title_lg("—", 28)
	_hero_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(_hero_name)
	_presence_box = _presence_badge()
	_presence_box.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	body.add_child(_presence_box)
	_set_presence("")

	var facts := GridContainer.new()
	facts.columns = 2
	facts.add_theme_constant_override("h_separation", 12)
	facts.add_theme_constant_override("v_separation", 12)
	facts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reputation_card = _stat_card(tr("%%SVC_LBL_REPUTATION"), "—", "", ServiceStyle.TEXT, 24)
	facts.add_child(_reputation_card)
	_corporation_card = _stat_card(tr("%%SVC_LBL_CORPORATION"), "—", "", ServiceStyle.TEXT, 16)
	facts.add_child(_corporation_card)
	body.add_child(facts)

	body.add_child(_spacer_v())
	body.add_child(_rule_h())
	body.add_child(ServiceStyle.label(tr("%%SVC_LBL_IDENTIFIER"), ServiceStyle.MUTED, ServiceStyle.SIZE_CAPTION))
	var id_row := _row(8)
	_id_value = ServiceStyle.label("—", ServiceStyle.TEXT_2, ServiceStyle.SIZE_CAPTION)
	_id_value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_id_value.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_id_value.clip_text = true
	id_row.add_child(_id_value)
	var copy := _action_button(id_row, tr("%%SVC_ACT_COPY"), func() -> void: _copy_id())
	ServiceStyle.apply_button_kind(copy, ServiceStyle.ButtonKind.GHOST)
	body.add_child(id_row)
	var role_row := _row(8)
	role_row.add_child(ServiceStyle.label(tr("%%SVC_LBL_ROLE") + " :", ServiceStyle.MUTED, ServiceStyle.SIZE_CAPTION))
	_role_value = ServiceStyle.label("—", ServiceStyle.TEXT, ServiceStyle.SIZE_CAPTION)
	role_row.add_child(_role_value)
	body.add_child(role_row)
	return card


## The portrait: a disc carrying the initial, [param side] px across.
func _avatar(side: float) -> Control:
	var panel := Panel.new()
	panel.custom_minimum_size = Vector2(side, side)
	panel.add_theme_stylebox_override("panel",
			ServiceStyle.flat(ServiceStyle.ACCENT_SOFT, int(side * 0.5), ServiceStyle.ACCENT, 2))
	_avatar_label = ServiceStyle.ares_label("?", ServiceStyle.ACCENT, int(side * 0.42))
	_avatar_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_avatar_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_avatar_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	panel.add_child(_avatar_label)
	return panel


## The presence pill (dot + word), recoloured when the profile lands.
func _presence_badge() -> PanelContainer:
	var pill := PanelContainer.new()
	ServiceStyle.apply_pill(pill, ServiceStyle.MUTED)
	var row := _row(8)
	_presence_light = Panel.new()
	_presence_light.custom_minimum_size = Vector2(9, 9)
	_presence_light.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_presence_light)
	_presence_label = ServiceStyle.label("", ServiceStyle.MUTED, ServiceStyle.SIZE_SMALL, true)
	row.add_child(_presence_label)
	pill.add_child(row)
	return pill


func _set_presence(status: String) -> void:
	var colour: Color = _presence_colour(status)
	ServiceStyle.apply_pill(_presence_box, colour)
	_presence_light.add_theme_stylebox_override("panel", ServiceStyle.flat(colour, 5, Color.TRANSPARENT, 0))
	var word: String = ServiceTypes.presence(status)
	_presence_label.text = word.left(1).to_upper() + word.substr(1)
	_presence_label.add_theme_color_override("font_color", colour)


## A vertical filler: pushes what follows to the foot of its column.
static func _spacer_v() -> Control:
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return spacer


## A hairline across its column.
static func _rule_h() -> Control:
	var rule := Panel.new()
	rule.custom_minimum_size = Vector2(0, 1)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rule.add_theme_stylebox_override("panel", ServiceStyle.flat(ServiceStyle.LINE, 0, Color.TRANSPARENT, 0))
	return rule


func _copy_id() -> void:
	if _id_value.text in ["", "—"]:
		return
	DisplayServer.clipboard_set(_id_value.text)
	_say(tr("%%SVC_MSG_ID_COPIED"), GOOD)


# ---------------------------------------------------------------------------------------------
# Modifier — public profile | roleplay sheet, actions at the foot
# ---------------------------------------------------------------------------------------------

func _build_edit_page(page: VBoxContainer) -> void:
	_frameless(page)
	page.add_theme_constant_override("separation", 20)
	var columns := _columns()
	page.add_child(columns)

	var public := _panel(tr("%%SVC_PROFILE_PUBLIC"))
	_name_field = _field(tr("%%SVC_PH_DISPLAY_NAME"), 0.0)
	public.body.add_child(_form_field(tr("%%SVC_LBL_DISPLAY_NAME"), _name_field))
	_bio_field = _textarea(tr("%%SVC_PH_BIO"), 180.0)
	_bio_field.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var bio := VBoxContainer.new()
	bio.add_theme_constant_override("separation", 0)
	bio.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bio.add_child(_toolbar(_bio_field))
	bio.add_child(_bio_field)
	var bio_field := _form_field(tr("%%SVC_LBL_BIOGRAPHY"), bio, tr("%%SVC_HINT_BBCODE"))
	bio_field.size_flags_vertical = Control.SIZE_EXPAND_FILL
	public.body.add_child(bio_field)
	columns.add_child(public)

	var rp := _panel(tr("%%SVC_LBL_RP_SHEET"))
	rp.head.add_child(ServiceStyle.label(tr("%%SVC_LBL_OPTIONAL"), ServiceStyle.MUTED, ServiceStyle.SIZE_CAPTION))
	_rp_name_field = _field(tr("%%SVC_PH_CHARACTER_NAME"), 0.0)
	_rp_alignment_field = _field(tr("%%SVC_PH_ALIGNMENT"), 0.0)
	rp.body.add_child(_field_row([
			_form_field(tr("%%SVC_LBL_CHARACTER_NAME"), _rp_name_field),
			_form_field(tr("%%SVC_LBL_ALIGNMENT"), _rp_alignment_field)]))
	_rp_story_field = _textarea(tr("%%SVC_PH_STORY"), 180.0)
	_rp_story_field.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var story := _form_field(tr("%%SVC_LBL_STORY"), _rp_story_field, tr("%%SVC_HINT_BBCODE"))
	story.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rp.body.add_child(story)
	columns.add_child(rp)

	var actions := _actions_bar()
	actions.add_child(_spacer())
	var cancel := _action_button(actions, tr("%%SVC_ACT_CANCEL"), func() -> void: _cancel_edit())
	ServiceStyle.apply_button_kind(cancel, ServiceStyle.ButtonKind.GHOST)
	_primary_button(actions, tr("%%SVC_ACT_SAVE_CHANGES"), func() -> void: _save())
	page.add_child(actions)


## The formatting strip glued over the biography (the mock-up's `.toolbar`): it wraps the selection.
func _toolbar(area: TextEdit) -> Control:
	var strip := PanelContainer.new()
	var box := ServiceStyle.flat(ServiceStyle.FIELD_BG, ServiceStyle.RADIUS_SMALL, ServiceStyle.LINE_2, 1, 6.0, 6.0)
	box.border_width_bottom = 0
	box.corner_radius_bottom_left = 0
	box.corner_radius_bottom_right = 0
	strip.add_theme_stylebox_override("panel", box)
	var row := _row(6)
	strip.add_child(row)
	for tool: Array in [["%%SVC_ACT_BOLD", "[b]", "[/b]"], ["%%SVC_ACT_ITALIC", "[i]", "[/i]"],
			["%%SVC_ACT_UNDERLINE", "[u]", "[/u]"], ["%%SVC_ACT_COLOR", "[color=#ffb800]", "[/color]"]]:
		var open_tag: String = tool[1]
		var close_tag: String = tool[2]
		var button := _action_button(row, tr(str(tool[0])), func() -> void: _wrap_bbcode(area, open_tag, close_tag))
		ServiceStyle.apply_button_kind(button, ServiceStyle.ButtonKind.GHOST)
		button.custom_minimum_size = Vector2(0, 36)
		ServiceStyle.font_of(button, ServiceStyle.SIZE_SMALL, true)
	return strip


## Cancel: the form goes back to what the profile says, and the player back to the profile.
func _cancel_edit() -> void:
	release_fields()
	_name_field.text = _loaded_name
	_bio_field.text = _loaded_bio
	_rp_name_field.text = str(_rp_original.get("characterName", ""))
	_rp_alignment_field.text = str(_rp_original.get("alignment", ""))
	_rp_story_field.text = str(_rp_original.get("story", ""))
	goto_segment(0)


# ---------------------------------------------------------------------------------------------
# Réputation — score + sanctions | history ; Activité — the feed
# ---------------------------------------------------------------------------------------------

func _build_reputation_page(page: VBoxContainer) -> void:
	_frameless(page)
	var columns := _columns()
	page.add_child(columns)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 20)
	columns.add_child(_fixed(left, 400.0))
	var score := PanelContainer.new()
	ServiceStyle.apply_card(score, 26.0)
	var score_box := VBoxContainer.new()
	score_box.add_theme_constant_override("separation", 8)
	score_box.add_child(ServiceStyle.label(tr("%%SVC_LBL_SCORE"), ServiceStyle.MUTED, ServiceStyle.SIZE_SMALL))
	_reputation_label = _big("—", ServiceStyle.ACCENT, 52)
	score_box.add_child(_reputation_label)
	score.add_child(score_box)
	left.add_child(score)

	var sanctions := PanelContainer.new()
	ServiceStyle.apply_card(sanctions, 26.0)
	_sanctions_box = VBoxContainer.new()
	_sanctions_box.add_theme_constant_override("separation", 10)
	sanctions.add_child(_sanctions_box)
	left.add_child(sanctions)
	_show_sanctions([], "")

	# The history is the paginated half of the reputation payload; the score rides every window.
	_page_events = ServicePage.new()
	_page_events.rows_key = "events"
	_page_events.total_keys = PackedStringArray(["eventsTotal"])
	_page_events.load_requested.connect(_load_reputation)
	_events_card = _panel(tr("%%SVC_LBL_HISTORY"))
	_events = _paged_into(_events_card, _page_events, tr("%%SVC_PROFILE_NO_EVENTS_TEXT"))
	columns.add_child(_events_card)


func _build_activity_page(page: VBoxContainer) -> void:
	_frameless(page)
	_page_activity = ServicePage.new()
	_page_activity.load_requested.connect(_load_activity)
	_activity_card = _panel(tr("%%SVC_LBL_RECENT_ACTIVITY"))
	_activity = _paged_into(_activity_card, _page_activity, tr("%%SVC_PROFILE_NO_ACTIVITY_TEXT"))
	page.add_child(_activity_card)


## A paged list inside [param card] (its caption already names it): the list, its empty state
## explained by [param empty_text], then the pager.
func _paged_into(card: Card, page: ServicePage, empty_text: String) -> ItemList:
	var list := _list(160.0)
	card.body.add_child(list)
	_empty_for(list, empty_text)
	card.body.add_child(_pager(page))
	return list


## The sanctions card: the active ones, or a green "none" pill. [param error] replaces both.
func _show_sanctions(lines: PackedStringArray, error: String) -> void:
	_clear(_sanctions_box)
	_sanctions_box.add_child(ServiceStyle.label(tr("%%SVC_LBL_ACTIVE_SANCTIONS"), ServiceStyle.MUTED,
			ServiceStyle.SIZE_SMALL))
	if error != "":
		var failed := ServiceStyle.label(error, WARN, ServiceStyle.SIZE_SMALL)
		failed.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_sanctions_box.add_child(failed)
		return
	if lines.is_empty():
		var pill := PanelContainer.new()
		pill.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		ServiceStyle.apply_pill(pill, GOOD)
		pill.add_child(ServiceStyle.label(tr("%%SVC_MSG_NO_SANCTIONS"), GOOD, ServiceStyle.SIZE_SMALL, true))
		_sanctions_box.add_child(pill)
		return
	for line: String in lines:
		var row := ServiceStyle.label(line, WARN, ServiceStyle.SIZE_SMALL, true)
		row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_sanctions_box.add_child(row)


# ---------------------------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------------------------

func refresh() -> void:
	if not _begin_refresh():
		return
	var profile: Dictionary = await PlayerServices.profile_get()
	var sanctions: Dictionary = await PlayerServices.my_sanctions()
	_apply_profile(profile)
	_apply_sanctions(sanctions)
	await _load_reputation()
	await _load_activity()
	_end_refresh()


func _load_reputation() -> void:
	var at: int = _page_events.offset
	var result: Dictionary = await PlayerServices.my_reputation(_page_events.limit, at)
	if _land(_page_events, at, result):
		_apply_reputation(result)


func _load_activity() -> void:
	var at: int = _page_activity.offset
	var result: Dictionary = await PlayerServices.my_activity(_page_activity.limit, at)
	if _land(_page_activity, at, result):
		_apply_activity(result)


func _apply_profile(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_say(HttpClient.describe_error(result), WARN)
		return
	if not (result.get("data") is Dictionary):
		_say(tr("%%SVC_MSG_UNEXPECTED_PROFILE"), WARN)
		return
	var profile: Dictionary = result.get("data")
	var display_name: String = str(profile.get("displayName", "—"))
	_hero_name.text = display_name
	_avatar_label.text = display_name.substr(0, 1).to_upper() if display_name not in ["", "—"] else "?"
	(_reputation_card.get_meta("value") as Label).text = "%d" % ServiceTypes.num(profile.get("reputation"))
	(_corporation_card.get_meta("value") as Label).text = _corporation_names(profile.get("corporations"))
	var presence: String = ""
	if profile.get("presence") is Dictionary:
		presence = str((profile.get("presence") as Dictionary).get("status", ""))
	_set_presence(presence)

	var bio: String = str(profile.get("biography", "")).strip_edges()
	_bio_display.text = bio
	_bio_display.get_parent().visible = bio != ""
	_bio_display.visible = bio != ""
	_bio_empty.visible = bio == ""
	_id_value.text = str(ServiceTypes.dash(profile.get("playerId")))
	_role_value.text = str(ServiceTypes.dash(profile.get("role")))

	var rp: Dictionary = profile.get("rpSheet") if profile.get("rpSheet") is Dictionary else {}
	var rp_text: String = _rp_text(rp)
	_rp_display.text = rp_text
	_rp_display.get_parent().visible = rp_text != ""
	_rp_display.visible = rp_text != ""
	_rp_empty.visible = rp_text == ""
	_rp_original = {
		"characterName": str(rp.get("characterName", "")).strip_edges(),
		"story": str(rp.get("story", "")).strip_edges(),
		"alignment": str(rp.get("alignment", "")).strip_edges(),
	}
	if not _rp_name_field.has_focus() and _rp_name_field.text == "":
		_rp_name_field.text = str(rp.get("characterName", ""))
	if not _rp_alignment_field.has_focus() and _rp_alignment_field.text == "":
		_rp_alignment_field.text = str(rp.get("alignment", ""))
	if not _rp_story_field.has_focus() and _rp_story_field.text == "":
		_rp_story_field.text = str(rp.get("story", ""))

	_loaded_name = display_name if display_name != "—" else ""
	_loaded_bio = str(profile.get("biography", ""))
	if not _name_field.has_focus() and _name_field.text == "":
		_name_field.text = _loaded_name
	if not _bio_field.has_focus() and _bio_field.text == "":
		_bio_field.text = _loaded_bio


func _apply_reputation(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_reputation_label.text = "—"
		_fill_list(_events, PackedStringArray([HttpClient.describe_error(result)]))
		return
	if not (result.get("data") is Dictionary):
		_reputation_label.text = "—"
		_fill_list(_events, PackedStringArray([tr("%%SVC_MSG_UNEXPECTED")]))
		return
	var data: Dictionary = result.get("data")
	_reputation_label.text = "%d" % ServiceTypes.num(data.get("reputation"))
	var lines := PackedStringArray()
	var metadata: Array = []
	for event: Dictionary in _page_events.rows(result):
		lines.append(ServiceTypes.reputation_event_line(event))
		metadata.append(event)
	if lines.is_empty():
		lines.append(tr("%%SVC_PROFILE_NO_EVENTS"))
	_fill_list(_events, lines, metadata)
	_events_card.set_count("%d" % _page_events.total if _page_events.total > 0 else "")


func _apply_sanctions(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_show_sanctions([], tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", "")))
		return
	var lines := PackedStringArray()
	for sanction: Dictionary in (result.get("data", []) if result.get("data") is Array else []):
		lines.append(ServiceTypes.sanction_line(sanction))
	_show_sanctions(lines, "")


func _apply_activity(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(_activity, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	for entry: Dictionary in _page_activity.rows(result):
		lines.append(ServiceTypes.activity_line(entry))
		metadata.append(entry)
	if lines.is_empty():
		lines.append(tr("%%SVC_PROFILE_NO_ACTIVITY"))
	_fill_list(_activity, lines, metadata)
	_activity_card.set_count("%d" % _page_activity.total if _page_activity.total > 0 else "")


## Every corporation the caller belongs to, or the "none" placeholder.
func _corporation_names(value: Variant) -> String:
	var names := PackedStringArray()
	if value is Array:
		for reference: Variant in value:
			if reference is Dictionary:
				names.append(ServiceTypes.corporation_ref_line(reference))
	if names.is_empty():
		return tr("%%SVC_MSG_NO_CORPORATION")
	return ", ".join(names)


## The roleplay sheet rendered as BBCode: character name, alignment, then the story. "" when empty.
func _rp_text(rp: Dictionary) -> String:
	var character_name: String = str(rp.get("characterName", "")).strip_edges()
	var alignment: String = str(rp.get("alignment", "")).strip_edges()
	var story: String = str(rp.get("story", "")).strip_edges()
	var head_parts := PackedStringArray()
	if character_name != "":
		head_parts.append("[b]%s[/b]" % character_name)
	if alignment != "":
		head_parts.append("[color=#f5b83d]%s[/color]" % alignment)
	var head: String = "  ·  ".join(head_parts)
	if story == "":
		return head
	return story if head == "" else head + "\n" + story


## Field-by-field comparison of two rpSheet dictionaries (so an untouched sheet is not re-sent).
static func _same_rp(a: Dictionary, b: Dictionary) -> bool:
	for key: String in ["characterName", "story", "alignment"]:
		if str(a.get(key, "")) != str(b.get(key, "")):
			return false
	return true


func _save() -> void:
	var patch: Dictionary = {}
	if _name_field.text.strip_edges() != "":
		patch["displayName"] = _name_field.text.strip_edges()
	if _bio_field.text.strip_edges() != "":
		patch["biography"] = _bio_field.text.strip_edges()
	var rp: Dictionary = {
		"characterName": _rp_name_field.text.strip_edges(),
		"story": _rp_story_field.text.strip_edges(),
		"alignment": _rp_alignment_field.text.strip_edges(),
	}
	if not _same_rp(rp, _rp_original):
		patch["rpSheet"] = rp
	if patch.is_empty():
		_say(tr("%%SVC_MSG_NOTHING_TO_SAVE"), WARN)
		return
	release_fields()
	var result: Dictionary = await PlayerServices.profile_update(patch)
	if _report(result, tr("%%SVC_MSG_PROFILE_SAVED")):
		_name_field.text = ""
		_bio_field.text = ""
		refresh()
