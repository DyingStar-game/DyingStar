extends ServicePanel

## App "Squad": temporary groups — a game between friends, whatever their corporation.
## A player belongs to at most one group: create one, invite from your contacts, manage
## the members and invitations, leave it or disband it. Covers /api/groups*,
## /api/me/groups and /api/me/group/invitations*.
##
## Tabs: 0 = my group, 1 = received invitations, 2 = create. Owner-only actions
## (edit, invite, kick, disband) appear only when the token says the group is ours.

var _summary: Label
var _description: Label
## No squad: the panel that says so, with the ways out (invitations, create).
var _none_card: ServicePanel.Card
## In a squad: the squad's panel (name, actions, members) and the owner's panel (edit, invite).
var _squad_columns: HBoxContainer
var _owner_card: ServicePanel.Card
var _actions: HBoxContainer
var _disband_button: Button
var _members: VBoxContainer
var _page_members: ServicePage
var _edit_box: VBoxContainer
var _edit_name: LineEdit
var _edit_description: LineEdit
var _edit_max: LineEdit
var _invite_box: VBoxContainer
var _invitees: VBoxContainer
var _page_invitees: ServicePage
var _invitations: VBoxContainer
var _invitations_card: ServicePanel.Card
var _page_invitations: ServicePage
var _create_name: LineEdit
var _create_description: TextEdit
var _create_max: LineEdit

## The current group (empty until /api/me/groups returns one), its id and whether the player
## owns it — the two drive the visibility of the owner-only actions.
var _group: Dictionary = {}
var _group_id: String = ""
var _is_owner: bool = false


func _build() -> void:
	var bar := _app_bar(tr("%%SVC_APP_SQUAD"), ServiceAppIcon.Kind.SQUAD)
	add_chrome(bar)

	var pages := _segments_pages(PackedStringArray([
			tr("%%SVC_TAB_MY_SQUAD"), tr("%%SVC_TAB_INVITATIONS"), tr("%%SVC_TAB_CREATE")]))
	_build_squad_page(pages[0])
	_build_invitations_page(pages[1])
	_build_create_page(pages[2])
	add_chrome(_status_line())


# ---------------------------------------------------------------------------------------------
# Tab 0 — my group
# ---------------------------------------------------------------------------------------------

## The owner's panel width (px): editing and inviting, beside the squad.
const OWNER_WIDTH: float = 620.0
## The create form's width (px): the mock-up's 720, scaled.
const CREATE_WIDTH: float = 900.0


## My squad, in the mock-up's panels: with none, one panel that says so and offers the invitations
## and the create form; with one, the squad (name, Leave / Disband, members) beside the owner's panel
## (edit it, invite a contact).
func _build_squad_page(page: VBoxContainer) -> void:
	_frameless(page)
	_none_card = _panel()
	page.add_child(_none_card)

	_squad_columns = _columns()
	var squad := _panel(tr("%%SVC_TAB_SQUAD"))
	_summary = _title_lg("—", 28)
	squad.body.add_child(_summary)
	_description = _label("", ServiceStyle.MUTED)
	_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	squad.body.add_child(_description)
	_actions = _actions_bar()
	ServiceStyle.apply_button_kind(_action_button(_actions, tr("%%SVC_ACT_LEAVE"), func() -> void: _leave()),
			ServiceStyle.ButtonKind.GHOST)
	_actions.add_child(_spacer())
	_disband_button = _action_button(_actions, tr("%%SVC_ACT_DISBAND"), func() -> void: _disband())
	ServiceStyle.apply_button_kind(_disband_button, ServiceStyle.ButtonKind.DANGER)
	squad.body.add_child(_actions)
	# Members as contact cards — same face as the Contacts app, with the kick on each row.
	squad.body.add_child(_subheading(tr("%%SVC_LBL_MEMBERS")))
	_members = _list_box()
	_page_members = ServicePage.new()
	_page_members.load_requested.connect(_load_members)
	squad.body.add_child(_scroll(_members))
	squad.body.add_child(_pager(_page_members))
	_squad_columns.add_child(squad)

	# The owner's panel: edit (refilled on every refresh, PATCH sends what is filled in), then invite.
	_owner_card = _panel(tr("%%SVC_TAB_EDIT"))
	_fixed(_owner_card, OWNER_WIDTH)
	_edit_box = VBoxContainer.new()
	_edit_box.add_theme_constant_override("separation", 16)
	_edit_name = _field(tr("%%SVC_PH_GROUP_NAME"), 0.0)
	_edit_description = _field(tr("%%SVC_PH_GROUP_DESCRIPTION"), 0.0)
	_edit_max = _number_field(tr("%%SVC_PH_MAX_MEMBERS"), 0.0)
	_edit_box.add_child(_form_field(tr("%%SVC_LBL_NAME"), _edit_name))
	_edit_box.add_child(_form_field(tr("%%SVC_LBL_DESCRIPTION"), _edit_description))
	_edit_box.add_child(_form_field(tr("%%SVC_LBL_MAX_MEMBERS"), _edit_max, tr("%%SVC_SQ_MAX_HINT")))
	var save_row := _actions_bar()
	save_row.add_child(_spacer())
	_primary_button(save_row, tr("%%SVC_ACT_SAVE"), func() -> void: _save_group())
	_edit_box.add_child(save_row)
	_owner_card.body.add_child(_edit_box)
	# Invite (while there is room): the contact list, one tap per invite.
	_invite_box = VBoxContainer.new()
	_invite_box.add_theme_constant_override("separation", 12)
	_invite_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_invite_box.add_child(_subheading(tr("%%SVC_LBL_INVITE_CONTACTS")))
	_invitees = _list_box()
	_page_invitees = ServicePage.new()
	_page_invitees.limit = 100
	_page_invitees.load_requested.connect(_load_invitees)
	_invite_box.add_child(_scroll(_invitees))
	_invite_box.add_child(_pager(_page_invitees))
	_owner_card.body.add_child(_invite_box)
	_squad_columns.add_child(_owner_card)
	page.add_child(_squad_columns)
	_show_no_squad(tr("%%SVC_SQ_NONE"), tr("%%SVC_SQ_NONE_TEXT"))


## The no-squad panel: [param title] over [param text] (the reason, or an error), with the two ways
## out — the invitations received and the create form.
func _show_no_squad(title: String, text: String) -> void:
	_clear(_none_card.body)
	var empty: Control = _empty_state(title, text)
	var box := empty.get_child(0) as VBoxContainer
	var icon := ServiceAppIcon.new()
	icon.kind = ServiceAppIcon.Kind.SQUAD
	icon.colour = ServiceStyle.LINE_HOVER
	icon.custom_minimum_size = Vector2(56, 56)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(icon)
	box.move_child(icon, 0)
	var ways := _row(12)
	ways.alignment = BoxContainer.ALIGNMENT_CENTER
	_action_button(ways, tr("%%SVC_SQ_SEE_INVITES"), func() -> void: goto_segment(1))
	_primary_button(ways, tr("%%SVC_SQ_CREATE_ONE"), func() -> void: goto_segment(2))
	box.add_child(ways)
	_none_card.body.add_child(empty)
	# No squad: only this panel shows, never the squad's own columns beside it.
	_none_card.visible = true
	_squad_columns.visible = false


# ---------------------------------------------------------------------------------------------
# Tab 1 — received invitations
# ---------------------------------------------------------------------------------------------

## Received invitations as cards — the group's name in the header, accept / decline on each row.
func _build_invitations_page(page: VBoxContainer) -> void:
	_frameless(page)
	_invitations_card = _panel(tr("%%SVC_TAB_INVITATIONS"))
	_invitations = _list_box()
	_page_invitations = ServicePage.new()
	_page_invitations.load_requested.connect(_load_invitations)
	_invitations_card.body.add_child(_scroll(_invitations))
	_invitations_card.body.add_child(_pager(_page_invitations))
	page.add_child(_invitations_card)


# ---------------------------------------------------------------------------------------------
# Tab 2 — create
# ---------------------------------------------------------------------------------------------

## The create form, one panel (the mock-up's "New squad"): name, description, member cap, then
## Cancel / Create.
func _build_create_page(page: VBoxContainer) -> void:
	_frameless(page)
	var card := _panel(tr("%%SVC_SQ_NEW"))
	_fixed(card, CREATE_WIDTH)
	_create_name = _field(tr("%%SVC_SQ_NAME_PH"), 0.0)
	_create_description = _textarea(tr("%%SVC_SQ_DESCRIPTION_PH"), 130.0)
	_create_max = _number_field(tr("%%SVC_SQ_MAX_PH"), 0.0)
	card.body.add_child(_form_field(tr("%%SVC_LBL_NAME"), _create_name))
	card.body.add_child(_form_field(tr("%%SVC_SQ_DESCRIPTION_OPT"), _create_description))
	var max_field := _form_field(tr("%%SVC_LBL_MAX_MEMBERS"), _create_max, tr("%%SVC_SQ_MAX_HINT"))
	max_field.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	max_field.custom_minimum_size.x = 300.0
	card.body.add_child(max_field)
	card.body.add_child(_spacer_v())
	var actions := _actions_bar()
	actions.add_child(_spacer())
	ServiceStyle.apply_button_kind(_action_button(actions, tr("%%SVC_ACT_CANCEL"), func() -> void: goto_segment(0)),
			ServiceStyle.ButtonKind.GHOST)
	_primary_button(actions, tr("%%SVC_SQ_CREATE"), func() -> void: _create_group())
	card.body.add_child(actions)
	page.add_child(card)


# ---------------------------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------------------------

func refresh() -> void:
	if not _begin_refresh():
		return
	var my: Dictionary = await PlayerServices.my_group()
	_apply_group(my)
	await _load_invitations()
	if _group_id != "":
		await _load_members()
		await _load_invitees()
	_end_refresh()


func _load_members() -> void:
	if _group_id == "":
		return
	var at: int = _page_members.offset
	var result: Dictionary = await PlayerServices.group_members(_group_id, _page_members.limit, at)
	if _land(_page_members, at, result):
		_apply_members(result)


func _load_invitees() -> void:
	var at: int = _page_invitees.offset
	var result: Dictionary = await PlayerServices.friends_list(_page_invitees.limit, at)
	if _land(_page_invitees, at, result):
		_apply_invitees(result)


func _load_invitations() -> void:
	var at: int = _page_invitations.offset
	var result: Dictionary = await PlayerServices.group_invitations(_page_invitations.limit, at)
	if _land(_page_invitations, at, result):
		_apply_invitations(result)


## /api/me/groups answers Group + joinedAt, or null when the player has no group.
func _apply_group(result: Dictionary) -> void:
	_group = {}
	_group_id = ""
	_is_owner = false
	if not bool(result.get("ok", false)):
		_show_no_squad(tr("%%SVC_MSG_ERROR_PREFIX") + " " + HttpClient.describe_error(result), "")
		_set_group_ui(false, false)
		return
	var data: Variant = result.get("data")
	if not (data is Dictionary):
		_show_no_squad(tr("%%SVC_SQ_NONE"), tr("%%SVC_SQ_NONE_TEXT"))
		_set_group_ui(false, false)
		return
	_group = data
	_group_id = str(_group.get("id", ""))
	_is_owner = str(_group.get("ownerId", "")) == PlayerServices.player_id()
	_edit_name.text = str(_group.get("name", ""))
	var description: Variant = _group.get("description")
	_edit_description.text = "" if description == null else str(description)
	_edit_max.text = str(ServiceTypes.num(_group.get("maxMembers"), 10))
	_set_group_ui(true, _is_owner)
	_render_summary()


## Toggle the owner-only blocks and the "create" entry. With no group, the lists that will
## not be reloaded are emptied right away.
func _set_group_ui(in_group: bool, owner: bool) -> void:
	_none_card.visible = not in_group
	_squad_columns.visible = in_group
	_owner_card.visible = owner
	_disband_button.visible = owner
	_edit_box.visible = owner
	_invite_box.visible = owner
	if not in_group:
		_clear(_members)
		_clear(_invitees)
		# Nothing to walk through any more: the members footer goes with the list it fed.
		_page_members.clear()


## The group line: name alone while the payload has no memberCount, name + head count once
## the members are known (and the invite disappears when the group is full).
func _render_summary() -> void:
	_summary.text = ServiceTypes.group_line(_group)
	var described: Variant = _group.get("description")
	_description.text = "" if described == null else str(described)
	_description.visible = _description.text != ""
	var full: bool = ServiceTypes.num(_group.get("memberCount")) \
			>= ServiceTypes.num(_group.get("maxMembers"), 10)
	_invite_box.visible = _is_owner and not full


func _apply_members(result: Dictionary) -> void:
	_clear(_members)
	if not bool(result.get("ok", false)):
		_members.add_child(_note_label(HttpClient.describe_error(result), WARN))
		return
	var count := 0
	for member: Dictionary in _page_members.rows(result):
		_members.add_child(_member_card(member))
		count += 1
	if count == 0:
		_members.add_child(_empty_state(tr("%%SVC_MSG_NO_MEMBERS"), ""))
	# /api/me/groups has no memberCount: the total of the list we just received IS the count.
	_group["memberCount"] = _page_members.total
	_render_summary()


func _apply_invitees(result: Dictionary) -> void:
	_clear(_invitees)
	if not bool(result.get("ok", false)):
		_invitees.add_child(_note_label(HttpClient.describe_error(result), WARN))
		return
	var count := 0
	for friend: Dictionary in _page_invitees.rows(result):
		_invitees.add_child(_invitee_card(friend))
		count += 1
	if count == 0:
		_invitees.add_child(_empty_state(tr("%%SVC_SOC_NO_CONTACTS"), ""))


func _apply_invitations(result: Dictionary) -> void:
	_clear(_invitations)
	if not bool(result.get("ok", false)):
		_invitations.add_child(_empty_state(HttpClient.describe_error(result), ""))
		return
	var count := 0
	for invitation: Dictionary in _page_invitations.rows(result):
		_invitations.add_child(_invitation_card(invitation))
		count += 1
	_invitations_card.set_count(str(_page_invitations.total) if count > 0 else "")
	if count == 0:
		_invitations.add_child(_empty_state(tr("%%SVC_SQ_NO_INVITES"), tr("%%SVC_SQ_NO_INVITES_TEXT")))


# ---------------------------------------------------------------------------------------------
# Mutations
# ---------------------------------------------------------------------------------------------

func _create_group() -> void:
	release_fields()
	var name: String = _create_name.text.strip_edges()
	if name.length() < 2:
		_say(tr("%%SVC_MSG_GROUP_NAME_REQUIRED"), WARN)
		return
	var body := {"name": name}
	var description: String = _create_description.text.strip_edges()
	if description != "":
		body["description"] = description
	var max_members: int = _max_value(_create_max)
	if max_members > 0:
		body["maxMembers"] = max_members
	if _report(await PlayerServices.group_create(body), tr("%%SVC_MSG_GROUP_CREATED")):
		_create_name.text = ""
		_create_description.text = ""
		_create_max.text = ""
		refresh()


func _save_group() -> void:
	release_fields()
	if _group_id == "":
		return
	var name: String = _edit_name.text.strip_edges()
	if name.length() < 2:
		_say(tr("%%SVC_MSG_GROUP_NAME_REQUIRED"), WARN)
		return
	var description: String = _edit_description.text.strip_edges()
	# An emptied description goes back to null: the only way to erase what is already written.
	var patch := {"name": name, "description": null if description == "" else description}
	var max_members: int = _max_value(_edit_max)
	if max_members > 0:
		patch["maxMembers"] = max_members
	if _report(await PlayerServices.group_update(_group_id, patch), tr("%%SVC_MSG_GROUP_UPDATED")):
		refresh()


func _leave() -> void:
	if _group_id == "":
		return
	if _report(await PlayerServices.group_leave(_group_id), tr("%%SVC_MSG_GROUP_LEFT")):
		refresh()


func _disband() -> void:
	if _group_id == "":
		return
	if _report(await PlayerServices.group_disband(_group_id), tr("%%SVC_MSG_GROUP_DISBANDED")):
		refresh()


func _remove_member(player_id: String) -> void:
	if _group_id == "" or player_id == "":
		return
	if _report(await PlayerServices.group_member_remove(_group_id, player_id),
			tr("%%SVC_MSG_MEMBER_REMOVED")):
		refresh()


func _invite(friend_id: String) -> void:
	if _group_id == "" or friend_id == "":
		return
	if _report(await PlayerServices.group_invite(_group_id, friend_id),
			tr("%%SVC_MSG_INVITE_SENT")):
		refresh()


func _invitation_action(invitation_id: int, accept: bool) -> void:
	if invitation_id < 0:
		return
	var result: Dictionary
	if accept:
		result = await PlayerServices.group_invitation_accept(invitation_id)
	else:
		result = await PlayerServices.group_invitation_decline(invitation_id)
	var success: String = tr("%%SVC_MSG_INVITATION_ACCEPTED") if accept \
			else tr("%%SVC_MSG_INVITATION_DECLINED")
	if _report(result, success):
		refresh()


# ---------------------------------------------------------------------------------------------
# Cards
# ---------------------------------------------------------------------------------------------

## One member as a contact card: avatar, name, presence (+ owner badge) — and the kick on every
## row but the owner's, only while we own the group (leaving the owner's own seat is Leave's job).
func _member_card(member: Dictionary) -> Control:
	var status := str(member.get("status", ""))
	var subtitle := ServiceTypes.presence(status)
	if bool(member.get("isOwner", false)):
		subtitle += "  ·  " + tr("%%SVC_LBL_OWNER")
	var actions: Array = []
	if _is_owner and not bool(member.get("isOwner", false)):
		var member_id := str(member.get("playerId", ""))
		actions.append([tr("%%SVC_ACT_REMOVE"), func() -> void: _remove_member(member_id)])
	return _contact_card(member, subtitle, status, actions)


## One contact as an invite row — one tap sends the invitation, no selection round-trip.
func _invitee_card(friend: Dictionary) -> Control:
	var status := str(friend.get("status", ""))
	var friend_id := str(friend.get("playerId", ""))
	return _contact_card(friend, ServiceTypes.presence(status), status,
			[[tr("%%SVC_ACT_INVITE"), func() -> void: _invite(friend_id)]])


## One received invitation as a card: the group's name carries the header (it is no player
## profile), the invite line the subtitle, accept / decline on the right.
func _invitation_card(invitation: Dictionary) -> Control:
	var group: Dictionary = invitation.get("group") if invitation.get("group") is Dictionary else {}
	var invitation_id := ServiceTypes.num(invitation.get("id"), -1)
	var profile := {"displayName": ServiceTypes.dash(group.get("name")), "playerId": ""}
	return _contact_card(profile, ServiceTypes.group_invitation_line(invitation), "",
			[[tr("%%SVC_ACT_ACCEPT"), func() -> void: _invitation_action(invitation_id, true)],
			[tr("%%SVC_ACT_DECLINE"), func() -> void: _invitation_action(invitation_id, false)]])


# ---------------------------------------------------------------------------------------------
# Local helpers
# ---------------------------------------------------------------------------------------------

## A column of rows that fills its scroll's height, so an empty state centres in the panel.
static func _list_box(separation: int = 10) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", separation)
	return box


## A vertical spacer: pushes a form's action bar to the panel's foot.
static func _spacer_v() -> Control:
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return spacer


## An autowrap note inside a card box (empty states and errors): a VBox gives it full width.
func _note_label(text: String, colour: Color) -> Label:
	var label := _label(text, colour)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


## A numeric field's value, or 0 when it is empty or unreadable (the service has its own defaults).
func _max_value(field: LineEdit) -> int:
	var raw: String = field.text.strip_edges()
	return int(raw) if raw.is_valid_int() else 0
