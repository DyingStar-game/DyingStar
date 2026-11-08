extends ServicePanel

## App « Contacts » : un carnet d'adresses façon téléphone. Le premier onglet est un master/detail —
## une liste alphabétique de cartes de contact (avatar généré + présence) avec un filtre en direct, et
## la fiche complète du contact sélectionné (identité, infos, bio en texte riche, actions). Les autres
## onglets couvrent les demandes, l'ajout d'un contact (recherche globale + suggestions) et les
## joueurs bloqués. Couvre /api/friends*, /api/profiles* et /api/blocks*.

## Onglets : 0 = carnet, 1 = demandes, 2 = ajouter, 3 = bloqués. Les conteneurs de chaque liste sont
## gardés pour qu'« Actualiser » puisse toutes les reconstruire.
var _roster: VBoxContainer
var _page_roster: ServicePage
var _filter: LineEdit
var _detail_box: VBoxContainer
var _incoming: VBoxContainer
var _outgoing: VBoxContainer
var _page_requests: ServicePage
var _suggestions: VBoxContainer
var _page_suggestions: ServicePage
var _results: VBoxContainer
var _page_search: ServicePage
var _blocks: VBoxContainer
var _page_blocks: ServicePage
var _search: LineEdit

## Le dernier payload d'amis, gardé pour que le filtre local re-rende sans refaire un appel réseau.
var _friends_cache: Array = []
## L'id du contact affiché, pour re-sélectionner la même fiche après un « Actualiser ».
var _selected_id: String = ""


func _build() -> void:
	var bar := _app_bar(tr("%%SVC_APP_CONTACTS"), ServiceAppIcon.Kind.CONTACTS)
	add_chrome(bar)

	var pages := _segments_pages(PackedStringArray([
			tr("%%SVC_TAB_CONTACTS"), tr("%%SVC_TAB_REQUESTS"),
			tr("%%SVC_TAB_ADD"), tr("%%SVC_TAB_BLOCKED")]))
	_build_contacts_page(pages[0])
	_build_requests_page(pages[1])
	_build_add_page(pages[2])
	_build_blocks_page(pages[3])
	add_chrome(_status_line())


# ---------------------------------------------------------------------------------------------
# Onglet 0 — le carnet (master/detail), the mock-up's two columns
# ---------------------------------------------------------------------------------------------

## The roster panel's width (px): the mock-up's 420, scaled to the tablet.
const ROSTER_WIDTH: float = 520.0

## Contact rows by player id, so the picked one is lit without rebuilding the list.
var _roster_rows: Dictionary = {}
var _roster_card: ServicePanel.Card


func _build_contacts_page(page: VBoxContainer) -> void:
	_frameless(page)
	# The roster is one big window rather than the API's default: its filter and its alphabetical
	# order are local, so the fewer pages the list is cut into, the more of the phone-book feeling
	# survives. Beyond a hundred contacts the footer takes over.
	_page_roster = ServicePage.new()
	_page_roster.limit = 100
	_page_roster.load_requested.connect(_load_roster)

	var columns := _columns()
	# Left: the filter over the contacts, as rich rows (avatar, presence, name).
	_roster_card = _panel(tr("%%SVC_TAB_CONTACTS"))
	_fixed(_roster_card, ROSTER_WIDTH)
	_filter = _field(tr("%%SVC_PH_FILTER_CONTACTS"), 0.0)
	_filter.text_changed.connect(func(_text: String) -> void: _render_roster())
	_roster_card.body.add_child(_filter)
	_roster = _list_box()
	_roster_card.body.add_child(_scroll(_roster))
	_roster_card.body.add_child(_pager(_page_roster))
	columns.add_child(_roster_card)

	# Right: the picked contact's sheet and what can be done with them.
	var sheet := _panel(tr("%%SVC_SOC_CONTACT_SHEET"))
	_detail_box = _list_box(12)
	sheet.body.add_child(_scroll(_detail_box))
	columns.add_child(sheet)
	page.add_child(columns)
	_render_detail_placeholder()


# ---------------------------------------------------------------------------------------------
# Onglet 1 — demandes: received | sent
# ---------------------------------------------------------------------------------------------

func _build_requests_page(page: VBoxContainer) -> void:
	_frameless(page)
	# One window carries both halves of the tab, so the footer sits under the first of them.
	_page_requests = ServicePage.new()
	_page_requests.rows_key = "incoming"
	_page_requests.total_keys = PackedStringArray(["incomingTotal", "outgoingTotal"])
	_page_requests.load_requested.connect(_load_requests)
	var columns := _columns()
	var received := _panel(tr("%%SVC_LBL_INCOMING_REQUESTS"))
	_incoming = _list_box()
	received.body.add_child(_scroll(_incoming))
	received.body.add_child(_pager(_page_requests))
	columns.add_child(received)
	var sent := _panel(tr("%%SVC_LBL_OUTGOING_REQUESTS"))
	_outgoing = _list_box()
	sent.body.add_child(_scroll(_outgoing))
	columns.add_child(sent)
	page.add_child(columns)


# ---------------------------------------------------------------------------------------------
# Onglet 2 — ajouter: the search on top, results | recently met below
# ---------------------------------------------------------------------------------------------

func _build_add_page(page: VBoxContainer) -> void:
	_frameless(page)
	page.add_theme_constant_override("separation", 24)
	var search_card := _panel("", "", 26.0, false)
	search_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var search_row := _row(14)
	_search = _field(tr("%%SVC_PH_PLAYER_NAME"), 240.0)
	_search.text_submitted.connect(func(_text: String) -> void: _run_search())
	search_row.add_child(_form_field(tr("%%SVC_LBL_SEARCH_PLAYER"), _search))
	var go := _primary_button(search_row, tr("%%SVC_ACT_SEARCH"), func() -> void: _run_search())
	go.size_flags_vertical = Control.SIZE_SHRINK_END
	search_card.body.add_child(search_row)
	page.add_child(search_card)

	var columns := _columns()
	_page_search = ServicePage.new()
	_page_search.load_requested.connect(_load_search)
	var results := _panel(tr("%%SVC_LBL_RESULTS"))
	_results = _list_box()
	results.body.add_child(_scroll(_results))
	results.body.add_child(_pager(_page_search))
	columns.add_child(results)
	_page_suggestions = ServicePage.new()
	_page_suggestions.load_requested.connect(_load_suggestions)
	var met := _panel(tr("%%SVC_LBL_RECENTLY_MET"))
	_suggestions = _list_box()
	met.body.add_child(_scroll(_suggestions))
	met.body.add_child(_pager(_page_suggestions))
	columns.add_child(met)
	page.add_child(columns)
	# Nothing asked yet: say how to start.
	_results.add_child(_empty_state("", tr("%%SVC_SOC_SEARCH_HINT")))


# ---------------------------------------------------------------------------------------------
# Onglet 3 — bloqués
# ---------------------------------------------------------------------------------------------

func _build_blocks_page(page: VBoxContainer) -> void:
	_frameless(page)
	_page_blocks = ServicePage.new()
	_page_blocks.load_requested.connect(_load_blocks)
	var card := _panel(tr("%%SVC_LBL_BLOCKED_PLAYERS"))
	_blocks = _list_box()
	card.body.add_child(_scroll(_blocks))
	card.body.add_child(_pager(_page_blocks))
	page.add_child(card)


# ---------------------------------------------------------------------------------------------
# Chargement
# ---------------------------------------------------------------------------------------------

func refresh() -> void:
	if not _begin_refresh():
		return
	await _load_roster()
	await _load_requests()
	await _load_suggestions()
	await _load_blocks()
	_end_refresh()


func _load_roster() -> void:
	var at: int = _page_roster.offset
	var result: Dictionary = await PlayerServices.friends_list(_page_roster.limit, at)
	if _land(_page_roster, at, result):
		_apply_friends(result)


func _load_requests() -> void:
	var at: int = _page_requests.offset
	var result: Dictionary = await PlayerServices.friend_requests(_page_requests.limit, at)
	if _land(_page_requests, at, result):
		_apply_requests(result)


func _load_suggestions() -> void:
	var at: int = _page_suggestions.offset
	var result: Dictionary = await PlayerServices.friend_suggestions(_page_suggestions.limit, at)
	if _land(_page_suggestions, at, result):
		_apply_suggestions(result)


func _load_blocks() -> void:
	var at: int = _page_blocks.offset
	var result: Dictionary = await PlayerServices.blocks_list(_page_blocks.limit, at)
	if _land(_page_blocks, at, result):
		_apply_blocks(result)


func _apply_friends(result: Dictionary) -> void:
	_friends_cache.clear()
	if bool(result.get("ok", false)):
		for friend: Dictionary in _page_roster.rows(result):
			_friends_cache.append(friend)
	var error: String = "" if bool(result.get("ok", false)) else HttpClient.describe_error(result)
	_render_roster(error)
	var still: Dictionary = _find_friend(_selected_id)
	if still.is_empty():
		_render_detail_placeholder()
	else:
		_render_detail(still)


# ---------------------------------------------------------------------------------------------
# Le carnet
# ---------------------------------------------------------------------------------------------

## Rebuild the visible contact rows from the cache, honouring the live filter.
func _render_roster(error: String = "") -> void:
	_clear(_roster)
	_roster_rows.clear()
	_roster_card.set_count("" if error != "" else str(_friends_cache.size()))
	if error != "":
		_roster.add_child(_empty_state(error, ""))
		return
	if _friends_cache.is_empty():
		_roster.add_child(_empty_state(tr("%%SVC_SOC_NO_CONTACTS"), tr("%%SVC_SOC_NO_CONTACTS_TEXT"),
				tr("%%SVC_ACT_ADD_CONTACT"), func() -> void: goto_segment(2)))
		return
	var needle: String = _filter.text.strip_edges().to_lower() if _filter != null else ""
	var shown: int = 0
	for friend: Dictionary in _sorted_friends():
		var name_text: String = str(friend.get("displayName", ""))
		if needle != "" and not name_text.to_lower().contains(needle):
			continue
		var status: String = str(friend.get("status", ""))
		var subtitle: String = ServiceTypes.presence(status) if status != "" else ""
		var row: Button = _contact_button(friend, subtitle, status)
		row.custom_minimum_size.y = 72
		var friend_id: String = str(friend.get("playerId", ""))
		ServiceStyle.apply_tile(row, friend_id == _selected_id)
		row.pressed.connect(func() -> void: _render_detail(friend))
		_roster.add_child(row)
		_roster_rows[friend_id] = row
		shown += 1
	if shown == 0:
		_roster.add_child(_empty_state(tr("%%SVC_MSG_NO_MATCH"), ""))


func _sorted_friends() -> Array:
	var sorted: Array = _friends_cache.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("displayName", "")).to_lower() < str(b.get("displayName", "")).to_lower())
	return sorted


func _find_friend(player_id: String) -> Dictionary:
	for friend: Dictionary in _friends_cache:
		if str(friend.get("playerId", "")) == player_id:
			return friend
	return {}


func _render_detail_placeholder() -> void:
	_clear(_detail_box)
	_selected_id = ""
	_light_selected()
	_detail_box.add_child(_empty_state("", tr("%%SVC_MSG_SELECT_CONTACT")))


func _render_detail(profile: Dictionary) -> void:
	_selected_id = str(profile.get("playerId", ""))
	_light_selected()
	_clear(_detail_box)
	var status: String = str(profile.get("status", ""))
	_detail_box.add_child(_detail_hero(profile, status))
	_detail_box.add_child(_detail_info(profile))
	_detail_box.add_child(_detail_bio(profile))
	_detail_box.add_child(_detail_actions(profile))


## La fiche : grand avatar badgé, nom, type/rôle et pilule de présence.
func _detail_hero(profile: Dictionary, status: String) -> Control:
	var card := PanelContainer.new()
	ServiceStyle.apply_card(card, 22.0)
	var row := _row(20)
	card.add_child(row)
	row.add_child(_avatar_initial(str(profile.get("displayName", "?")), 80.0, status))

	var identity := VBoxContainer.new()
	identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	identity.add_theme_constant_override("separation", 4)
	identity.alignment = BoxContainer.ALIGNMENT_CENTER
	identity.add_child(_title_lg(str(profile.get("displayName", "—")), 28))
	var sub_parts := PackedStringArray()
	if str(profile.get("entityType", "")) != "":
		sub_parts.append(str(profile.get("entityType")))
	if str(profile.get("role", "")) != "":
		sub_parts.append(str(profile.get("role")))
	var location: String = ServiceTypes.location_text(profile.get("location"))
	if location != "":
		sub_parts.append(location)
	identity.add_child(_label(" · ".join(sub_parts) if sub_parts.size() > 0 else "—", ServiceStyle.MUTED))
	row.add_child(identity)

	if status != "":
		row.add_child(_presence_pill(status))
	return card


func _detail_info(profile: Dictionary) -> Control:
	var entries: Array = [
		[tr("%%SVC_LBL_REPUTATION"), ServiceTypes.dash(profile.get("reputation"))],
		[tr("%%SVC_LBL_FACTION"), ServiceTypes.dash(profile.get("faction"))],
		[tr("%%SVC_LBL_ROLE"), ServiceTypes.dash(profile.get("role"))],
		[tr("%%SVC_LBL_FRIEND_SINCE"), ServiceTypes.dash(profile.get("friendsSince"))],
		[tr("%%SVC_LBL_IDENTIFIER"), ServiceTypes.dash(profile.get("playerId"))],
	]
	return _sheet_card(tr("%%SVC_LBL_INFORMATION"), _kv_grid(entries))


func _detail_bio(profile: Dictionary) -> Control:
	var bio: String = str(profile.get("biography", "")).strip_edges()
	var body := _rich_text(40.0)
	if bio == "":
		body.text = "[i][color=#99a3b5]%s[/color][/i]" % tr("%%SVC_MSG_NO_BIO")
	else:
		body.text = bio
	return _sheet_card(tr("%%SVC_LBL_BIOGRAPHY"), body)


func _detail_actions(profile: Dictionary) -> Control:
	var player_id: String = str(profile.get("playerId", ""))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	column.add_child(_compose_box(profile, player_id))
	var row := _actions_bar()
	# Ouvre la messagerie privée avec ce contact : ChatNetwork épingle ce correspondant comme
	# la conversation en cours et révèle le journal (fiche → "Message").
	_action_button(row, tr("%%SVC_ACT_MESSAGE"), func() -> void: _message_player(profile, player_id))
	row.add_child(_spacer())
	ServiceStyle.apply_button_kind(_action_button(row, tr("%%SVC_ACT_REMOVE"),
			func() -> void: _remove_friend(player_id)), ServiceStyle.ButtonKind.GHOST)
	ServiceStyle.apply_button_kind(_action_button(row, tr("%%SVC_ACT_BLOCK"),
			func() -> void: _block_player(player_id)), ServiceStyle.ButtonKind.DANGER)
	column.add_child(row)
	return column


## Write to this contact without leaving the card — the "sms" gesture: type, send, stay here.
##
## Publishing goes straight at the peer's topic ([method ChatNetwork.publish_dm_to]) rather than
## through the pinned thread: answering someone here must not yank the player's own conversation
## away from whoever they were writing to in the message box. Enter sends, like the chat input.
func _compose_box(profile: Dictionary, player_id: String) -> Control:
	var card := PanelContainer.new()
	ServiceStyle.apply_card(card, 18.0)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	card.add_child(column)
	column.add_child(_label(tr("%%SVC_LBL_MESSAGE_TO") % str(profile.get("displayName", "—")),
			ServiceStyle.TEXT))

	var row := _row(8)
	column.add_child(row)
	var field := _field(tr("%%SVC_PLH_MESSAGE"), 220.0)
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)
	var send := _primary_button(row, tr("%%SVC_ACT_SEND_MESSAGE"),
			func() -> void: _send_dm(player_id, field))
	field.text_submitted.connect(func(_text: String) -> void: _send_dm(player_id, field))
	send.tooltip_text = tr("%%SVC_TIP_SEND_MESSAGE")
	return card


## Send [param field]'s text to [param player_id] and clear it. Blank text is not sent, and a send
## refused by the transport (not connected) leaves the text in place so nothing is lost.
func _send_dm(player_id: String, field: LineEdit) -> void:
	if player_id == "" or field.text.strip_edges() == "":
		return
	if not ChatNetwork.publish_dm_to(player_id, field.text):
		push_warning("[friends] DM to %s dropped: chat not connected" % player_id)
		return
	field.clear()
	field.release_focus()


func _message_player(profile: Dictionary, player_id: String) -> void:
	if player_id == "":
		return
	# The card already holds the name, so the pinned bar fills in at once instead of
	# waiting on social to answer who this is.
	ChatNetwork.start_dm(player_id, str(profile.get("displayName", "")))


# ---------------------------------------------------------------------------------------------
# Demandes
# ---------------------------------------------------------------------------------------------

func _apply_requests(result: Dictionary) -> void:
	_clear(_incoming)
	_clear(_outgoing)
	if not bool(result.get("ok", false)):
		var error: String = tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))
		_incoming.add_child(_empty_state(error, ""))
		_outgoing.add_child(_empty_state(error, ""))
		return
	_fill_requests(_incoming, _page_requests.rows(result), true)
	_fill_requests(_outgoing, ServicePage.items_of(result, "outgoing"), false)


func _fill_requests(box: VBoxContainer, source: Variant, incoming: bool) -> void:
	if not (source is Array) or (source as Array).is_empty():
		if incoming:
			box.add_child(_empty_state(tr("%%SVC_SOC_NO_REQUESTS"), tr("%%SVC_SOC_NO_REQUESTS_TEXT")))
		else:
			box.add_child(_empty_state(tr("%%SVC_SOC_NO_SENT"), tr("%%SVC_SOC_NO_SENT_TEXT")))
		return
	for request: Dictionary in source:
		var profile: Dictionary = request.get("player", {}) if request.get("player") is Dictionary else {}
		var request_id: int = ServiceTypes.num(request.get("id"))
		var actions: Array = []
		if incoming:
			actions.append([tr("%%SVC_ACT_ACCEPT"), func() -> void: _accept_request(request_id)])
			actions.append([tr("%%SVC_ACT_DECLINE"), func() -> void: _decline_request(request_id)])
		else:
			actions.append([tr("%%SVC_ACT_CANCEL"), func() -> void: _decline_request(request_id)])
		box.add_child(_contact_card(profile, tr("%%SVC_FMT_REQUEST_NUM") % request_id, "", actions))


func _accept_request(request_id: int) -> void:
	if _report(await PlayerServices.friend_accept(request_id), tr("%%SVC_MSG_REQUEST_ACCEPTED")):
		refresh()


func _decline_request(request_id: int) -> void:
	if _report(await PlayerServices.friend_decline(request_id), tr("%%SVC_MSG_REQUEST_DECLINED")):
		refresh()


# ---------------------------------------------------------------------------------------------
# Ajouter
# ---------------------------------------------------------------------------------------------

func _run_search() -> void:
	release_fields()
	# A new question: back to the first window, which runs it with whatever is typed now.
	_page_search.reset()


func _load_search() -> void:
	var at: int = _page_search.offset
	var result: Dictionary = await PlayerServices.profiles_search(_search.text.strip_edges(),
			_page_search.limit, "", at)
	if _land(_page_search, at, result):
		_fill_search(result)


func _fill_search(result: Dictionary) -> void:
	_clear(_results)
	if not bool(result.get("ok", false)):
		_results.add_child(_empty_state(HttpClient.describe_error(result), ""))
		return
	var count: int = 0
	for profile: Dictionary in _page_search.rows(result):
		_results.add_child(_add_contact_card(profile))
		count += 1
	if count == 0:
		_results.add_child(_empty_state(tr("%%SVC_SOC_NO_RESULTS"), tr("%%SVC_SOC_NO_RESULTS_TEXT")))


func _apply_suggestions(result: Dictionary) -> void:
	_clear(_suggestions)
	if not bool(result.get("ok", false)):
		_suggestions.add_child(_empty_state(tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", "")), ""))
		return
	var count: int = 0
	for suggestion: Dictionary in _page_suggestions.rows(result):
		var encounters: int = ServiceTypes.num(suggestion.get("encounters"))
		_suggestions.add_child(_add_contact_card(suggestion, tr("%%SVC_FMT_MET_TIMES") % encounters))
		count += 1
	if count == 0:
		_suggestions.add_child(_empty_state(tr("%%SVC_SOC_NO_SUGGESTIONS"), tr("%%SVC_SOC_NO_SUGGESTIONS_TEXT")))


func _add_contact_card(profile: Dictionary, subtitle: String = "") -> Control:
	var player_id: String = str(profile.get("playerId", ""))
	var sub: String = subtitle if subtitle != "" else ServiceTypes.entity_type_label(profile.get("entityType"))
	return _contact_card(profile, sub, "",
			[[tr("%%SVC_ACT_ADD"), func() -> void: _add_friend(player_id)]])


func _add_friend(player_id: String) -> void:
	if player_id == "":
		_say(tr("%%SVC_MSG_NO_ID"), WARN)
		return
	_say(tr("%%SVC_MSG_REQUEST_SENDING"), DIM)
	_report(await PlayerServices.friend_send(player_id), tr("%%SVC_MSG_REQUEST_SENT"))


# ---------------------------------------------------------------------------------------------
# Bloqués
# ---------------------------------------------------------------------------------------------

func _apply_blocks(result: Dictionary) -> void:
	_clear(_blocks)
	if not bool(result.get("ok", false)):
		_blocks.add_child(_empty_state(tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", "")), ""))
		return
	var count: int = 0
	for block: Dictionary in _page_blocks.rows(result):
		var player_id: String = str(block.get("playerId", ""))
		_blocks.add_child(_contact_card(block,
				tr("%%SVC_FMT_BLOCKED_ON") % ServiceTypes.dash(block.get("blockedAt")),
				"", [[tr("%%SVC_ACT_UNBLOCK"), func() -> void: _unblock(player_id)]]))
		count += 1
	if count == 0:
		_blocks.add_child(_empty_state(tr("%%SVC_SOC_NO_BLOCKED"), tr("%%SVC_SOC_NO_BLOCKED_TEXT")))


func _remove_friend(player_id: String) -> void:
	if player_id == "":
		return
	if _report(await PlayerServices.friend_remove(player_id), tr("%%SVC_MSG_FRIEND_REMOVED")):
		refresh()


func _block_player(player_id: String) -> void:
	if player_id == "":
		return
	if _report(await PlayerServices.block_add(player_id), tr("%%SVC_MSG_PLAYER_BLOCKED")):
		refresh()


func _unblock(player_id: String) -> void:
	if player_id == "":
		return
	if _report(await PlayerServices.block_remove(player_id), tr("%%SVC_MSG_PLAYER_UNBLOCKED")):
		refresh()


# ---------------------------------------------------------------------------------------------
# Petits utilitaires locaux
# ---------------------------------------------------------------------------------------------

## A column of rows that fills its scroll's height, so an empty state centres in the panel.
static func _list_box(separation: int = 10) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", separation)
	return box


## Light the roster row of the contact on show, and only it.
func _light_selected() -> void:
	for id: String in _roster_rows:
		var row: Button = _roster_rows[id]
		if is_instance_valid(row):
			ServiceStyle.apply_tile(row, id == _selected_id)


## Une carte à en-tête (caption) et corps, pour la fiche contact.
func _sheet_card(caption: String, body: Control) -> Control:
	var card := PanelContainer.new()
	ServiceStyle.apply_card(card, 20.0)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	box.add_child(_subheading(caption))
	box.add_child(body)
	card.add_child(box)
	return card
