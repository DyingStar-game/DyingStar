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
	_action_button(bar, tr("%%SVC_ACT_REFRESH"), func() -> void: refresh())
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
# Onglet 0 — le carnet (master/detail)
# ---------------------------------------------------------------------------------------------

func _build_contacts_page(page: VBoxContainer) -> void:
	# La page doit remplir la hauteur pour que les deux colonnes prennent toute la tablette.
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# The roster is one big window rather than the API's default: its filter and its alphabetical
	# order are local, so the fewer pages the list is cut into, the more of the phone-book feeling
	# survives. Beyond a hundred contacts the footer takes over.
	_page_roster = ServicePage.new()
	_page_roster.limit = 100
	_page_roster.load_requested.connect(_load_roster)

	var columns := _row(18)
	columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Colonne gauche : liste des contacts. The filter that narrows it is the segment's control, so
	# it sits in the column beside the detail column the tablet draws next to the card.
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 10)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.0
	left.custom_minimum_size = Vector2(300, 0)
	_filter = _field(tr("%%SVC_PH_FILTER_CONTACTS"), 0.0)
	_filter.text_changed.connect(func(_text: String) -> void: _render_roster())
	_side_page(0).add_child(_filter)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_roster = VBoxContainer.new()
	_roster.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_roster.add_theme_constant_override("separation", 8)
	scroll.add_child(_roster)
	left.add_child(scroll)
	left.add_child(_pager(_page_roster))
	columns.add_child(left)

	# Colonne droite : la fiche du contact sélectionné.
	var right := ScrollContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 1.4
	right.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_detail_box = VBoxContainer.new()
	_detail_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_box.add_theme_constant_override("separation", 12)
	right.add_child(_detail_box)
	columns.add_child(right)

	page.add_child(columns)
	_render_detail_placeholder()


# ---------------------------------------------------------------------------------------------
# Onglet 1 — demandes
# ---------------------------------------------------------------------------------------------

func _build_requests_page(page: VBoxContainer) -> void:
	# One window carries both halves of the tab, so the footer sits under the first of them.
	_page_requests = ServicePage.new()
	_page_requests.rows_key = "incoming"
	_page_requests.total_keys = PackedStringArray(["incomingTotal", "outgoingTotal"])
	_page_requests.load_requested.connect(_load_requests)
	_incoming = VBoxContainer.new()
	_incoming.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_incoming.add_theme_constant_override("separation", 8)
	_paged_box(page, tr("%%SVC_LBL_INCOMING_REQUESTS"), _page_requests, _incoming)
	_outgoing = VBoxContainer.new()
	_outgoing.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_outgoing.add_theme_constant_override("separation", 8)
	page.add_child(_titled(tr("%%SVC_LBL_OUTGOING_REQUESTS"), _outgoing, true))


# ---------------------------------------------------------------------------------------------
# Onglet 2 — ajouter (recherche + suggestions)
# ---------------------------------------------------------------------------------------------

func _build_add_page(page: VBoxContainer) -> void:
	# The query is the segment's control: it runs from the column, the hits land in the card.
	var side := _side_page(2)
	var search_row := _row()
	_search = _field(tr("%%SVC_PH_PLAYER_NAME"), 240.0)
	_search.text_submitted.connect(func(_text: String) -> void: _run_search())
	search_row.add_child(_search)
	_action_button(search_row, tr("%%SVC_ACT_SEARCH"), func() -> void: _run_search())
	side.add_child(_titled(tr("%%SVC_LBL_SEARCH_PLAYER"), search_row))
	_page_search = ServicePage.new()
	_page_search.load_requested.connect(_load_search)
	_results = VBoxContainer.new()
	_results.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_results.add_theme_constant_override("separation", 8)
	_paged_box(page, tr("%%SVC_LBL_RESULTS"), _page_search, _results)
	_page_suggestions = ServicePage.new()
	_page_suggestions.load_requested.connect(_load_suggestions)
	_suggestions = VBoxContainer.new()
	_suggestions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_suggestions.add_theme_constant_override("separation", 8)
	_paged_box(page, tr("%%SVC_LBL_RECENTLY_MET"), _page_suggestions, _suggestions)


# ---------------------------------------------------------------------------------------------
# Onglet 3 — bloqués
# ---------------------------------------------------------------------------------------------

func _build_blocks_page(page: VBoxContainer) -> void:
	_page_blocks = ServicePage.new()
	_page_blocks.load_requested.connect(_load_blocks)
	_blocks = VBoxContainer.new()
	_blocks.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_blocks.add_theme_constant_override("separation", 8)
	_paged_box(page, tr("%%SVC_LBL_BLOCKED_PLAYERS"), _page_blocks, _blocks)


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
	if error != "":
		_roster.add_child(_empty_label(error))
		return
	if _friends_cache.is_empty():
		_roster.add_child(_empty_label(tr("%%SVC_MSG_NO_CONTACTS")))
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
		row.pressed.connect(func() -> void: _render_detail(friend))
		_roster.add_child(row)
		shown += 1
	if shown == 0:
		_roster.add_child(_empty_label(tr("%%SVC_MSG_NO_MATCH")))


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
	_detail_box.add_child(_empty_label(tr("%%SVC_MSG_SELECT_CONTACT")))


func _render_detail(profile: Dictionary) -> void:
	_selected_id = str(profile.get("playerId", ""))
	_clear(_detail_box)
	var status: String = str(profile.get("status", ""))
	_detail_box.add_child(_detail_hero(profile, status))
	_detail_box.add_child(_detail_info(profile))
	_detail_box.add_child(_detail_bio(profile))
	_detail_box.add_child(_detail_actions(profile))


## La fiche : grand avatar badgé, nom, type/rôle et pilule de présence.
func _detail_hero(profile: Dictionary, status: String) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel",
			ServiceStyle.flat(ServiceStyle.PANEL, ServiceStyle.RADIUS, ServiceStyle.BORDER, 1, 20.0, 16.0))
	var row := _row(16)
	card.add_child(row)
	row.add_child(_avatar_initial(str(profile.get("displayName", "?")), 72.0, status))

	var identity := VBoxContainer.new()
	identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	identity.add_theme_constant_override("separation", 4)
	identity.alignment = BoxContainer.ALIGNMENT_CENTER
	var name_label := _label(str(profile.get("displayName", "—")), ServiceStyle.TEXT)
	ServiceStyle.font_of(name_label, 24, true)
	identity.add_child(name_label)
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
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 6)
	for entry: Array in entries:
		grid.add_child(_label(str(entry[0]), ServiceStyle.MUTED))
		var value := _label(str(entry[1]), ServiceStyle.TEXT)
		value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(value)
	return _sheet_card(tr("%%SVC_LBL_INFORMATION"), grid)


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
	var row := _row()
	_action_button(row, tr("%%SVC_ACT_REMOVE"), func() -> void: _remove_friend(player_id))
	_action_button(row, tr("%%SVC_ACT_BLOCK"), func() -> void: _block_player(player_id))
	return row


# ---------------------------------------------------------------------------------------------
# Demandes
# ---------------------------------------------------------------------------------------------

func _apply_requests(result: Dictionary) -> void:
	_clear(_incoming)
	_clear(_outgoing)
	if not bool(result.get("ok", false)):
		var error: String = tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))
		_incoming.add_child(_empty_label(error))
		_outgoing.add_child(_empty_label(error))
		return
	_fill_requests(_incoming, _page_requests.rows(result), true)
	_fill_requests(_outgoing, ServicePage.items_of(result, "outgoing"), false)


func _fill_requests(box: VBoxContainer, source: Variant, incoming: bool) -> void:
	if not (source is Array) or (source as Array).is_empty():
		box.add_child(_empty_label(tr("%%SVC_MSG_NO_INCOMING") if incoming else tr("%%SVC_MSG_NO_OUTGOING")))
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
		_results.add_child(_empty_label(HttpClient.describe_error(result)))
		return
	var count: int = 0
	for profile: Dictionary in _page_search.rows(result):
		_results.add_child(_add_contact_card(profile))
		count += 1
	if count == 0:
		_results.add_child(_empty_label(tr("%%SVC_MSG_NO_RESULTS")))


func _apply_suggestions(result: Dictionary) -> void:
	_clear(_suggestions)
	if not bool(result.get("ok", false)):
		_suggestions.add_child(_empty_label(tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))))
		return
	var count: int = 0
	for suggestion: Dictionary in _page_suggestions.rows(result):
		var encounters: int = ServiceTypes.num(suggestion.get("encounters"))
		_suggestions.add_child(_add_contact_card(suggestion, tr("%%SVC_FMT_MET_TIMES") % encounters))
		count += 1
	if count == 0:
		_suggestions.add_child(_empty_label(tr("%%SVC_MSG_NO_SUGGESTIONS")))


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
		_blocks.add_child(_empty_label(tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))))
		return
	var count: int = 0
	for block: Dictionary in _page_blocks.rows(result):
		var player_id: String = str(block.get("playerId", ""))
		_blocks.add_child(_contact_card(block,
				tr("%%SVC_FMT_BLOCKED_ON") % ServiceTypes.dash(block.get("blockedAt")),
				"", [[tr("%%SVC_ACT_UNBLOCK"), func() -> void: _unblock(player_id)]]))
		count += 1
	if count == 0:
		_blocks.add_child(_empty_label(tr("%%SVC_MSG_NO_BLOCKED")))


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

func _empty_label(text: String) -> Label:
	var label := _label(text, ServiceStyle.MUTED)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


## Une carte à en-tête (caption) et corps, pour la fiche contact.
func _sheet_card(caption: String, body: Control) -> Control:
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
