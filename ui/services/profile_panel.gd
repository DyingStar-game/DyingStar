extends ServicePanel

## App « Identité » : the caller's profile (hero card + biography + identity facts), an edit form, the
## reputation/sanctions journal, and the activity feed. Reads GET /api/me (+ /reputation, /sanctions,
## /activity) and writes PATCH /api/me.

var _avatar_label: Label
var _hero_name: Label
var _hero_sub: Label
var _presence: Label
var _bio_display: RichTextLabel
var _rp_display: RichTextLabel
var _info_values: Dictionary = {}  # fact key -> its value Label
var _name_field: LineEdit
var _bio_field: TextEdit
var _rp_name_field: LineEdit
var _rp_alignment_field: LineEdit
var _rp_story_field: TextEdit
var _rp_original: Dictionary = {}  # last loaded rpSheet, to patch only when edited
var _reputation_label: Label
var _events: ItemList
var _page_events: ServicePage
var _sanctions: ItemList
var _activity: ItemList
var _page_activity: ServicePage


func _build() -> void:
	var bar := _app_bar(tr("%%SVC_APP_IDENTITY"), ServiceAppIcon.Kind.IDENTITY)
	_action_button(bar, tr("%%SVC_ACT_REFRESH"), func() -> void: refresh())
	add_chrome(bar)

	var pages := _segments_pages(PackedStringArray([
			tr("%%SVC_TAB_PROFILE"), tr("%%SVC_TAB_EDIT"),
			tr("%%SVC_TAB_REPUTATION"), tr("%%SVC_TAB_ACTIVITY")]))
	_build_profil_page(pages[0])
	# The edit form is the whole of the second segment: it lives in the column, which then takes the
	# card. The reading pages (profile, reputation, activity) keep the card to themselves.
	_build_edit_page(_side_page(1))
	_build_reputation_page(pages[2])
	_build_activity_page(pages[3])
	add_chrome(_status_line())


# ---------------------------------------------------------------------------------------------
# Profil — hero card, biography, identity facts
# ---------------------------------------------------------------------------------------------

func _build_profil_page(page: VBoxContainer) -> void:
	page.add_child(_hero_card())

	var bio_box := VBoxContainer.new()
	bio_box.add_theme_constant_override("separation", 6)
	_bio_display = _rich_text(60.0)
	bio_box.add_child(_bio_display)
	page.add_child(_card(tr("%%SVC_LBL_BIOGRAPHY"), bio_box))

	var rp_box := VBoxContainer.new()
	rp_box.add_theme_constant_override("separation", 6)
	_rp_display = _rich_text(90.0)
	rp_box.add_child(_rp_display)
	page.add_child(_card(tr("%%SVC_LBL_RP_SHEET"), rp_box))

	var facts := VBoxContainer.new()
	facts.add_theme_constant_override("separation", 8)
	facts.add_child(_info_row(tr("%%SVC_LBL_IDENTIFIER"), "id"))
	facts.add_child(_info_row(tr("%%SVC_LBL_ROLE"), "role"))
	page.add_child(_card(tr("%%SVC_LBL_INFORMATION"), facts))


func _hero_card() -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel",
			ServiceStyle.flat(ServiceStyle.PANEL, ServiceStyle.RADIUS, ServiceStyle.BORDER, 1, 22.0, 18.0))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	card.add_child(row)

	row.add_child(_avatar())

	var identity := VBoxContainer.new()
	identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	identity.add_theme_constant_override("separation", 2)
	_hero_name = _label("—", ServiceStyle.TEXT)
	ServiceStyle.font_of(_hero_name, 26, true)
	identity.add_child(_hero_name)
	_hero_sub = _label("", ServiceStyle.MUTED)
	ServiceStyle.font_of(_hero_sub, 15)
	identity.add_child(_hero_sub)
	row.add_child(identity)

	_presence = _label("", ServiceStyle.MUTED)
	_presence.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_presence)
	return card


func _avatar() -> Control:
	var panel := Panel.new()
	panel.custom_minimum_size = Vector2(64, 64)
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	panel.add_theme_stylebox_override("panel",
			ServiceStyle.flat(ServiceStyle.ACCENT_SOFT, 32, ServiceStyle.ACCENT_LINE, 1))
	_avatar_label = Label.new()
	_avatar_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_avatar_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_avatar_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_avatar_label.add_theme_color_override("font_color", ServiceStyle.ACCENT)
	ServiceStyle.font_of(_avatar_label, 28, true)
	panel.add_child(_avatar_label)
	return panel


## A card with a small caption header over its body.
func _card(caption: String, body: Control) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel",
			ServiceStyle.flat(ServiceStyle.PANEL_ALT, ServiceStyle.RADIUS, ServiceStyle.BORDER, 1, 18.0, 14.0))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var header := _label(caption.to_upper(), ServiceStyle.MUTED)
	ServiceStyle.font_of(header, 12, true)
	box.add_child(header)
	box.add_child(body)
	card.add_child(box)
	return card


func _info_row(caption: String, key: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	var name_label := _label(caption, ServiceStyle.MUTED)
	name_label.custom_minimum_size = Vector2(150, 0)
	row.add_child(name_label)
	var value := _label("—", ServiceStyle.TEXT)
	value.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(value)
	_info_values[key] = value
	return row


# ---------------------------------------------------------------------------------------------
# Modifier
# ---------------------------------------------------------------------------------------------

func _build_edit_page(side: VBoxContainer) -> void:
	var form := VBoxContainer.new()
	form.add_theme_constant_override("separation", 10)
	_name_field = _field(tr("%%SVC_PH_DISPLAY_NAME"), 320.0)
	_bio_field = _textarea(tr("%%SVC_PH_BIO"), 180.0)
	form.add_child(_label(tr("%%SVC_LBL_DISPLAY_NAME"), ServiceStyle.MUTED))
	form.add_child(_name_field)
	form.add_child(_label(tr("%%SVC_LBL_BIOGRAPHY"), ServiceStyle.MUTED))
	var toolbar := _row(8)
	_action_button(toolbar, tr("%%SVC_ACT_BOLD"), func() -> void: _wrap_bbcode(_bio_field, "[b]", "[/b]"))
	_action_button(toolbar, tr("%%SVC_ACT_ITALIC"), func() -> void: _wrap_bbcode(_bio_field, "[i]", "[/i]"))
	_action_button(toolbar, tr("%%SVC_ACT_UNDERLINE"), func() -> void: _wrap_bbcode(_bio_field, "[u]", "[/u]"))
	_action_button(toolbar, tr("%%SVC_ACT_COLOR"),
			func() -> void: _wrap_bbcode(_bio_field, "[color=#ffb800]", "[/color]"))
	toolbar.add_child(_label("  " + tr("%%SVC_HINT_BBCODE"), ServiceStyle.MUTED))
	form.add_child(toolbar)
	form.add_child(_bio_field)
	_rp_name_field = _field(tr("%%SVC_PH_CHARACTER_NAME"), 320.0)
	_rp_alignment_field = _field(tr("%%SVC_PH_ALIGNMENT"), 320.0)
	_rp_story_field = _textarea(tr("%%SVC_PH_STORY"), 140.0)
	form.add_child(_label(tr("%%SVC_LBL_CHARACTER_NAME"), ServiceStyle.MUTED))
	form.add_child(_rp_name_field)
	form.add_child(_label(tr("%%SVC_LBL_ALIGNMENT"), ServiceStyle.MUTED))
	form.add_child(_rp_alignment_field)
	form.add_child(_label(tr("%%SVC_LBL_STORY"), ServiceStyle.MUTED))
	form.add_child(_rp_story_field)
	_action_button(form, tr("%%SVC_ACT_SAVE"), func() -> void: _save())
	side.add_child(_card(tr("%%SVC_LBL_EDIT_PROFILE"), form))


# ---------------------------------------------------------------------------------------------
# Réputation / Activité
# ---------------------------------------------------------------------------------------------

func _build_reputation_page(page: VBoxContainer) -> void:
	_reputation_label = _label("—", ServiceStyle.ACCENT)
	ServiceStyle.font_of(_reputation_label, 22, true)
	page.add_child(_card(tr("%%SVC_LBL_SCORE"), _reputation_label))
	# The history is the paginated half of the reputation payload; the score rides every window.
	_page_events = ServicePage.new()
	_page_events.rows_key = "events"
	_page_events.total_keys = PackedStringArray(["eventsTotal"])
	_page_events.load_requested.connect(_load_reputation)
	_events = _paged_list(page, tr("%%SVC_LBL_HISTORY"), _page_events, 180.0)
	_sanctions = _list(180.0)
	page.add_child(_titled(tr("%%SVC_LBL_ACTIVE_SANCTIONS"), _sanctions, true))


func _build_activity_page(page: VBoxContainer) -> void:
	_page_activity = ServicePage.new()
	_page_activity.load_requested.connect(_load_activity)
	_activity = _paged_list(page, tr("%%SVC_LBL_RECENT_ACTIVITY"), _page_activity, 320.0)


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
	var corporation_text: String = _corporation_names(profile.get("corporations"))
	_hero_sub.text = tr("%%SVC_HERO_SUB") % [
		corporation_text, ServiceTypes.num(profile.get("reputation"))]
	var presence: String = ""
	if profile.get("presence") is Dictionary:
		presence = str((profile.get("presence") as Dictionary).get("status", ""))
	_presence.text = ServiceTypes.presence(presence)
	_presence.add_theme_color_override("font_color",
			ServiceStyle.GOOD if presence == "online" else ServiceStyle.MUTED)

	var bio: String = str(profile.get("biography", "")).strip_edges()
	if bio == "":
		_bio_display.text = "[i][color=#99a3b5]%s[/color][/i]" % tr("%%SVC_MSG_NO_BIO")
	else:
		_bio_display.text = bio
	_info_values["id"].text = ServiceTypes.dash(profile.get("playerId"))
	_info_values["role"].text = ServiceTypes.dash(profile.get("role"))

	var rp: Dictionary = profile.get("rpSheet") if profile.get("rpSheet") is Dictionary else {}
	_rp_display.text = _rp_text(rp)
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

	if not _name_field.has_focus() and _name_field.text == "":
		_name_field.text = display_name
	if not _bio_field.has_focus() and _bio_field.text == "":
		_bio_field.text = str(profile.get("biography", ""))


func _apply_reputation(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_reputation_label.text = HttpClient.describe_error(result)
		return
	if not (result.get("data") is Dictionary):
		_reputation_label.text = tr("%%SVC_MSG_UNEXPECTED")
		return
	var data: Dictionary = result.get("data")
	_reputation_label.text = "%d" % ServiceTypes.num(data.get("reputation"))
	var lines := PackedStringArray()
	var metadata: Array = []
	for event: Dictionary in _page_events.rows(result):
		lines.append(ServiceTypes.reputation_event_line(event))
		metadata.append(event)
	_fill_list(_events, lines, metadata)


func _apply_sanctions(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(_sanctions, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	for sanction: Dictionary in (result.get("data", []) if result.get("data") is Array else []):
		lines.append(ServiceTypes.sanction_line(sanction))
		metadata.append(sanction)
	if lines.is_empty():
		lines.append(tr("%%SVC_MSG_NO_SANCTIONS"))
	_fill_list(_sanctions, lines, metadata)


func _apply_activity(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(_activity, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	for entry: Dictionary in _page_activity.rows(result):
		lines.append(ServiceTypes.activity_line(entry))
		metadata.append(entry)
	_fill_list(_activity, lines, metadata)


## The hero subtitle shows every corporation the caller belongs to, or the "none" placeholder.
func _corporation_names(value: Variant) -> String:
	var names := PackedStringArray()
	if value is Array:
		for reference: Variant in value:
			if reference is Dictionary:
				names.append(ServiceTypes.corporation_ref_line(reference))
	if names.is_empty():
		return tr("%%SVC_MSG_NO_CORPORATION")
	return ", ".join(names)


## The roleplay sheet rendered as BBCode: character name, alignment, then the story.
func _rp_text(rp: Dictionary) -> String:
	var character_name: String = str(rp.get("characterName", "")).strip_edges()
	var alignment: String = str(rp.get("alignment", "")).strip_edges()
	var story: String = str(rp.get("story", "")).strip_edges()
	if character_name == "" and alignment == "" and story == "":
		return "[i][color=#99a3b5]%s[/color][/i]" % tr("%%SVC_MSG_NO_RP")
	var head_parts := PackedStringArray()
	if character_name != "":
		head_parts.append("[b]%s[/b]" % character_name)
	if alignment != "":
		head_parts.append("[color=#ffb800]%s[/color]" % alignment)
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
