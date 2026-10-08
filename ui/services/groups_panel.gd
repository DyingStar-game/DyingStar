extends ServicePanel

## App "Squad": temporary groups — a game between friends, whatever their corporation.
## A player belongs to at most one group: create one, invite from your contacts, manage
## the members and invitations, leave it or disband it. Covers /api/groups*,
## /api/me/groups and /api/me/group/invitations*.
##
## Tabs: 0 = my group, 1 = received invitations, 2 = create. Owner-only actions
## (edit, invite, kick, disband) appear only when the token says the group is ours.

var _summary: Label
var _create_shortcut: HBoxContainer
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
var _page_invitations: ServicePage
var _create_name: LineEdit
var _create_description: LineEdit
var _create_max: LineEdit

## The current group (empty until /api/me/groups returns one), its id and whether the player
## owns it — the two drive the visibility of the owner-only actions.
var _group: Dictionary = {}
var _group_id: String = ""
var _is_owner: bool = false


func _build() -> void:
	var bar := _app_bar(tr("%%SVC_APP_SQUAD"), ServiceAppIcon.Kind.SQUAD)
	_action_button(bar, tr("%%SVC_ACT_REFRESH"), func() -> void: refresh())
	add_chrome(bar)

	var pages := _segments_pages(PackedStringArray([
			tr("%%SVC_TAB_MY_SQUAD"), tr("%%SVC_TAB_INVITATIONS"), tr("%%SVC_TAB_CREATE")]))
	_build_squad_page(pages[0])
	_build_invitations_page(pages[1])
	# The create form is the whole of the third segment: it goes to the column, which then takes
	# the card.
	_build_create_page(_side_page(2))
	add_chrome(_status_line())


# ---------------------------------------------------------------------------------------------
# Tab 0 — my group
# ---------------------------------------------------------------------------------------------

func _build_squad_page(page: VBoxContainer) -> void:
	var side := _side_page(0)
	_summary = _label(tr("%%SVC_MSG_NO_GROUP"), DIM)
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(_titled(tr("%%SVC_LBL_GROUP"), _summary))

	# No group: the straight path to creation. What you CAN do with the group — create, leave,
	# disband, edit it — is the column's half; the members and the contacts it can invite stay.
	_create_shortcut = _row()
	_action_button(_create_shortcut, tr("%%SVC_ACT_CREATE_GROUP"), func() -> void: goto_segment(2))
	side.add_child(_create_shortcut)

	_actions = _row()
	_action_button(_actions, tr("%%SVC_ACT_LEAVE"), func() -> void: _leave())
	_disband_button = _action_button(_actions, tr("%%SVC_ACT_DISBAND"), func() -> void: _disband())
	side.add_child(_actions)

	# Members as contact cards — same face as the Contacts app, with the kick on each row.
	var members_scroll := _card_list(160.0)
	_members = members_scroll[1]
	_page_members = ServicePage.new()
	_page_members.load_requested.connect(_load_members)
	_paged_box(page, tr("%%SVC_LBL_MEMBERS"), _page_members, members_scroll[0])

	# Edit (owner): refilled on every refresh, PATCH only sends what is filled in.
	var edit := VBoxContainer.new()
	edit.add_theme_constant_override("separation", 8)
	_edit_name = _field(tr("%%SVC_PH_GROUP_NAME"), 260.0)
	_edit_description = _field(tr("%%SVC_PH_GROUP_DESCRIPTION"), 360.0)
	_edit_max = _number_field(tr("%%SVC_PH_MAX_MEMBERS"), 140.0)
	edit.add_child(_label(tr("%%SVC_LBL_NAME"), DIM))
	edit.add_child(_edit_name)
	edit.add_child(_label(tr("%%SVC_LBL_DESCRIPTION"), DIM))
	edit.add_child(_edit_description)
	edit.add_child(_label(tr("%%SVC_LBL_MAX_MEMBERS"), DIM))
	edit.add_child(_edit_max)
	_action_button(edit, tr("%%SVC_ACT_SAVE"), func() -> void: _save_group())
	_edit_box = _titled(tr("%%SVC_TAB_EDIT"), edit)
	side.add_child(_edit_box)

	# Invite (owner, while there is room): the contact list, one tap per invite.
	var invitees_scroll := _card_list(160.0)
	_invitees = invitees_scroll[1]
	_page_invitees = ServicePage.new()
	_page_invitees.limit = 100
	_page_invitees.load_requested.connect(_load_invitees)
	_invite_box = _paged_box(page, tr("%%SVC_LBL_INVITE_CONTACTS"), _page_invitees,
			invitees_scroll[0])


# ---------------------------------------------------------------------------------------------
# Tab 1 — received invitations
# ---------------------------------------------------------------------------------------------

## Received invitations as cards — the group's name in the header, accept / decline on each row.
func _build_invitations_page(page: VBoxContainer) -> void:
	var scroll := _card_list(260.0)
	_invitations = scroll[1]
	_page_invitations = ServicePage.new()
	_page_invitations.load_requested.connect(_load_invitations)
	_paged_box(page, tr("%%SVC_LBL_PENDING_REQUESTS"), _page_invitations, scroll[0])


# ---------------------------------------------------------------------------------------------
# Tab 2 — create
# ---------------------------------------------------------------------------------------------

func _build_create_page(side: VBoxContainer) -> void:
	var create := VBoxContainer.new()
	create.add_theme_constant_override("separation", 8)
	_create_name = _field(tr("%%SVC_PH_GROUP_NAME"), 260.0)
	_create_description = _field(tr("%%SVC_PH_GROUP_DESCRIPTION"), 360.0)
	_create_max = _number_field(tr("%%SVC_PH_MAX_MEMBERS"), 140.0)
	create.add_child(_label(tr("%%SVC_LBL_NAME"), DIM))
	create.add_child(_create_name)
	create.add_child(_label(tr("%%SVC_LBL_DESCRIPTION"), DIM))
	create.add_child(_create_description)
	create.add_child(_label(tr("%%SVC_LBL_MAX_MEMBERS"), DIM))
	create.add_child(_create_max)
	_action_button(create, tr("%%SVC_ACT_CREATE_GROUP"), func() -> void: _create_group())
	side.add_child(_titled(tr("%%SVC_TAB_CREATE"), create))


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
		_summary.text = tr("%%SVC_MSG_ERROR_PREFIX") + " " + HttpClient.describe_error(result)
		_set_group_ui(false, false)
		return
	var data: Variant = result.get("data")
	if not (data is Dictionary):
		_summary.text = tr("%%SVC_MSG_NO_GROUP")
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
	_create_shortcut.visible = not in_group
	_actions.visible = in_group
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
		_members.add_child(_note_label(tr("%%SVC_MSG_NO_MEMBERS"), DIM))
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
		_invitees.add_child(_note_label(tr("%%SVC_MSG_NO_CONTACTS"), DIM))


func _apply_invitations(result: Dictionary) -> void:
	_clear(_invitations)
	if not bool(result.get("ok", false)):
		_invitations.add_child(_note_label(HttpClient.describe_error(result), WARN))
		return
	var count := 0
	for invitation: Dictionary in _page_invitations.rows(result):
		_invitations.add_child(_invitation_card(invitation))
		count += 1
	if count == 0:
		_invitations.add_child(_note_label(tr("%%SVC_MSG_NO_PENDING"), DIM))


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

## A bounded scroll around a card box: cards grow, the page does not. Returns [scroll, box].
func _card_list(min_height: float) -> Array:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, min_height)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	return [scroll, box]


## An autowrap note inside a card box (empty states and errors): a VBox gives it full width.
func _note_label(text: String, colour: Color) -> Label:
	var label := _label(text, colour)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


## A numeric field's value, or 0 when it is empty or unreadable (the service has its own defaults).
func _max_value(field: LineEdit) -> int:
	var raw: String = field.text.strip_edges()
	return int(raw) if raw.is_valid_int() else 0
