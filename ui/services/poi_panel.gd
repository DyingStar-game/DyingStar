extends ServicePanel

## App « Points of interest » : the POIs of the caller's scope (owned, read-only grants, public),
## the detail of one POI with its grants, the create/edit form, and the POIs of the player's
## corporations. Covers /api/me/pois* and /api/corporations/{corporationId}/pois*.
##
## Laid out as the A.R.E.S. OS mock-up (2026-11): a list panel beside a detail panel, a single form
## panel, and an empty state for a player who belongs to no corporation.

## `[raw value, translation key]` pairs for the visibility select; the raw value rides in the item
## metadata (see [method ServicePanel._option_enum]).
const VISIBILITY_ENTRIES: Array = [
	["private", "%%SVC_ENUM_POI_PRIVATE"],
	["public", "%%SVC_ENUM_POI_PUBLIC"],
]
## Who the form creates the POI for: blank is the caller (the endpoint's default), anything else is
## the organization picked underneath. `political` would be legal too — nothing to pick one with yet.
const OWNER_ENTRIES: Array = [
	["", "%%SVC_LBL_OWNER_ME"],
	["corporation", "%%SVC_ENUM_HOLDER_CORPORATION"],
]
## The list panels' width (px): the mock-up's 480, scaled to the tablet's 1920.
const LIST_WIDTH: float = 560.0

## My POIs: the list, its panel (count), the detail panel's content, the grants and the grantee picker.
var _pois: RowList
var _page_pois: ServicePage
var _pois_card: Card
var _pois_empty: Control
var _pois_scroll: Control
var _detail_box: VBoxContainer
var _shares: RowList
var _target: ServiceTargetPicker
## The id whose detail is open, so a refresh can restore the selection it wiped.
var _detail_id: String = ""
## The form, and the id it edits ("" = a blank form, ready to create).
var _form_card: Card
var _form_name: LineEdit
var _form_description: TextEdit
## The chosen place, read-only: system · scene · x,y,z. The player never types coordinates — they
## take theirs (« Here ») or pick one on the chart.
var _form_where: Label
## The two place tiles: "my current position" and "pick on the chart"; the lit one is how the place
## was last taken.
var _tile_here: Button
var _tile_chart: Button
var _form_radius: LineEdit
var _form_visibility: OptionButton
var _form_owner: OptionButton
var _form_owner_picker: ServiceTargetPicker
## The form's buttons: a POI is either CREATED or edited, never both at once, so only the pair the
## current mode needs is on show (Save with no id to save would be a dead button).
var _form_new: Button
var _form_create: Button
var _form_save: Button
var _edit_id: String = ""
## The place the form will send: system, scene and position (see [PlayerLocation]). Null until a
## place has been taken — a form that is never placed has nothing to say about where it is.
var _placed: Dictionary = {}
## Set while this form has asked the chart for a place and the answer has not come back yet.
##
## It is what says "this form is the one waiting": the console hands a place to the app that asked
## for it, and a form that never asked must not take one — the mission builder's marker used to
## land here, and the player was sent to the inventory instead of back to their mission.
var _awaiting_place: bool = false
## The corporation tab: the player's corporations, the one on show, and its list and detail.
var _corps: Array = []
var _corp_id: String = ""
var _corp_bar_box: HBoxContainer
var _corp_empty: Control
var _corp_columns: HBoxContainer
var _corp_pois: RowList
var _page_corp_pois: ServicePage
var _corp_pois_card: Card
var _corp_pois_empty: Control
var _corp_pois_scroll: Control
var _corp_detail_box: VBoxContainer


func _build() -> void:
	var bar := _app_bar(tr("%%SVC_APP_POIS"), ServiceAppIcon.Kind.POIS)
	add_chrome(bar)

	var pages := _segments_pages(PackedStringArray([
			tr("%%SVC_TAB_MY_POIS"), tr("%%SVC_TAB_CREATE"), tr("%%SVC_TAB_CORP_POIS")]))
	_build_mine(pages[0])
	# The create/edit form is the whole of the second segment: one panel, the page's own.
	_build_form(pages[1])
	_build_corp(pages[2])
	add_chrome(_status_line())


func refresh() -> void:
	if not _begin_refresh():
		return
	var open_id := _detail_id
	await _load_pois()
	# Re-selecting the row reopens its detail (the list announces the pick).
	_select_poi(_pois, open_id)
	await _load_corps()
	_end_refresh()


func _load_pois() -> void:
	var at: int = _page_pois.offset
	var result: Dictionary = await PlayerServices.poi_list(_page_pois.limit, at)
	if _land(_page_pois, at, result):
		_apply_pois(_page_pois, result, _pois, _pois_card, _pois_empty, _pois_scroll)


# ---------------------------------------------------------------------------------------------
# My POIs — list, detail, grants
# ---------------------------------------------------------------------------------------------

func _build_mine(page: VBoxContainer) -> void:
	_frameless(page)
	var columns := _columns()
	page.add_child(columns)

	_page_pois = ServicePage.new()
	_page_pois.load_requested.connect(_load_pois)
	_pois = RowList.new()
	_pois.row_selected.connect(func(_meta: Variant) -> void: _load_detail())
	_pois_card = _panel(tr("%%SVC_TAB_MY_POIS"), "0")
	_pois_empty = _empty_state(tr("%%SVC_MSG_NO_POIS"), tr("%%SVC_EMPTY_POIS_TEXT"),
			tr("%%SVC_ACT_CREATE_POI"), func() -> void: goto_segment(1))
	_pois_scroll = _list_body(_pois_card, _pois, _pois_empty, _page_pois)
	columns.add_child(_fixed(_pois_card, LIST_WIDTH))

	var detail := _panel(tr("%%SVC_LBL_DETAIL"))
	_detail_box = detail.body
	columns.add_child(detail)

	# The grants panel content is built once and kept: the picker holds a search field the screen
	# contract shields, and the share list feeds the revoke.
	_shares = RowList.new()
	_target = ServiceTargetPicker.new()
	_target.setup(ServiceTargetPicker.Mask.EITHER, true)
	adopt_field(_target.search_field())
	_clear_detail()


## Fill a list panel's body: the rows in a scroll, the empty state in their place while there are
## none, the pager under them. Returns the scroll, for the caller to toggle against the empty state.
func _list_body(card: Card, list: RowList, empty: Control, page: ServicePage) -> Control:
	var scroll := _scroll(list)
	card.body.add_child(scroll)
	empty.visible = false
	card.body.add_child(empty)
	card.body.add_child(_pager(page))
	return scroll


## Open the detail and the grants of the row the player picked.
func _load_detail() -> void:
	var poi: Dictionary = _selected_poi(_pois)
	if poi.is_empty():
		return
	var result: Dictionary = await PlayerServices.poi_get(str(poi.get("id", "")))
	if not bool(result.get("ok", false)):
		_detail_message(_detail_box, HttpClient.describe_error(result), WARN)
		return
	if not (result.get("data") is Dictionary):
		_detail_message(_detail_box, tr("%%SVC_MSG_UNEXPECTED"), WARN)
		return
	var view: Dictionary = result.get("data")
	_detail_id = str(view.get("id", ""))
	_render_detail(_detail_box, view, true)
	_fill_shares(view.get("shares"))


## The detail of [param poi] in [param box]: its badge, kind and name, its facts, its description,
## and — on the player's own list ([param mine]) — its actions and grants.
func _render_detail(box: VBoxContainer, poi: Dictionary, mine: bool) -> void:
	_detach_kept(box)
	_clear(box)
	var head := _row(18)
	head.add_child(_poi_badge(64.0))
	var titles := VBoxContainer.new()
	titles.add_theme_constant_override("separation", 6)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_child(_tag(ServiceTypes.poi_visibility_label(poi.get("visibility"))))
	titles.add_child(_title_lg(ServiceTypes.dash(poi.get("name")), 26))
	head.add_child(titles)
	box.add_child(head)

	var radius: Variant = poi.get("radiusM")
	box.add_child(_kv_grid([
		[tr("%%SVC_LBL_LOCATION"), ServiceTypes.poi_location(poi)],
		[tr("%%SVC_LBL_OWNER"), ServiceTypes.poi_grantee_label(poi.get("ownerType"))],
		[tr("%%SVC_LBL_RADIUS_ZONE"), "—" if radius == null else "%d m" % ServiceTypes.num(radius)],
	]))
	var description: String = _text(poi.get("description")).strip_edges()
	if description != "":
		var body := _label(description, ServiceStyle.TEXT_2)
		body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(_titled(tr("%%SVC_LBL_DESCRIPTION"), body))
	if not mine:
		return

	var actions := _actions_bar()
	_action_button(actions, tr("%%SVC_ACT_EDIT"), _edit_selected)
	ServiceStyle.apply_button_kind(_action_button(actions, tr("%%SVC_ACT_DELETE_POI"), _delete_selected),
			ServiceStyle.ButtonKind.DANGER)
	box.add_child(actions)

	# The grants: who may read this point, and the picker that names a new grantee. Acting on what
	# the detail shows.
	box.add_child(_subheading(tr("%%SVC_LBL_SHARES")))
	box.add_child(_shares)
	box.add_child(_form_field(tr("%%SVC_LBL_RECIPIENT"), _target))
	var grants := _row(12)
	_action_button(grants, tr("%%SVC_ACT_GRANT"), _grant)
	_action_button(grants, tr("%%SVC_ACT_REVOKE"), _revoke)
	_action_button(grants, tr("%%SVC_ACT_TRANSFER"), _transfer)
	box.add_child(grants)


## Take the kept controls (the share list, the grantee picker) out of [param box] before it is
## emptied, so clearing the detail never frees them.
func _detach_kept(box: VBoxContainer) -> void:
	for kept: Control in [_shares, _target]:
		if kept != null and kept.get_parent() != null and box.is_ancestor_of(kept):
			kept.get_parent().remove_child(kept)


## A single message in a detail panel (nothing selected, an error).
func _detail_message(box: VBoxContainer, text: String, colour: Color = DIM) -> void:
	_detach_kept(box)
	_clear(box)
	if colour == DIM:
		box.add_child(_empty_state("", text))
		return
	var line := _label(text, colour)
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(line)


func _fill_shares(value: Variant) -> void:
	var rows: Array = []
	for share: Dictionary in (value if value is Array else []):
		rows.append({
			"name": ServiceTypes.poi_grantee_label(share.get("granteeType")),
			"sub": "%s  ·  %s" % [ServiceTypes.dash(share.get("granteeId")), ServiceTypes.dash(share.get("createdAt"))],
			"meta": share,
		})
	if rows.is_empty():
		rows.append({"name": tr("%%SVC_MSG_NONE"), "meta": null})
	_shares.set_rows(rows)


func _edit_selected() -> void:
	var poi: Dictionary = _selected_poi(_pois)
	if poi.is_empty():
		_say(tr("%%SVC_MSG_SELECT_POI"), WARN)
		return
	_fill_form(poi)
	goto_segment(1)


func _delete_selected() -> void:
	var poi: Dictionary = _selected_poi(_pois)
	if poi.is_empty():
		_say(tr("%%SVC_MSG_SELECT_POI"), WARN)
		return
	var poi_id := str(poi.get("id", ""))
	var result: Dictionary = await PlayerServices.poi_delete(poi_id)
	if _report(result, tr("%%SVC_MSG_POI_DELETED")):
		if _edit_id == poi_id:
			_blank_form()
		_clear_detail()
		refresh()


## Grant read-only access to the picked target. The grantee never gets write access, so this is
## also the row a read-only colleague belongs on.
func _grant() -> void:
	var poi: Dictionary = _selected_poi(_pois)
	if poi.is_empty():
		_say(tr("%%SVC_MSG_SELECT_POI"), WARN)
		return
	if _target.picked_id() == "":
		_say(tr("%%SVC_MSG_NEED_TARGET"), WARN)
		return
	var result: Dictionary = await PlayerServices.poi_share(str(poi.get("id", "")),
			_target.picked_kind(), _target.picked_id())
	if _report(result, tr("%%SVC_MSG_POI_SHARED")):
		await _load_detail()


## Revoke the grant selected in the grant list — and only that one: the revoke names both halves
## of the grant, so a stray tap cannot take away somebody else's access.
func _revoke() -> void:
	var poi: Dictionary = _selected_poi(_pois)
	if poi.is_empty():
		_say(tr("%%SVC_MSG_SELECT_POI"), WARN)
		return
	var share: Variant = _shares.selected_meta()
	if not (share is Dictionary):
		_say(tr("%%SVC_MSG_SELECT_GRANT"), WARN)
		return
	var grant: Dictionary = share
	var result: Dictionary = await PlayerServices.poi_unshare(str(poi.get("id", "")),
			str(grant.get("granteeType", "")), str(grant.get("granteeId", "")))
	if _report(result, tr("%%SVC_MSG_POI_UNSHARED")):
		await _load_detail()


## Hand the selected POI over to the picked target. Ownership moves outright: the previous owner
## keeps no implicit grant, so the transfer is not a share in disguise.
func _transfer() -> void:
	var poi: Dictionary = _selected_poi(_pois)
	if poi.is_empty():
		_say(tr("%%SVC_MSG_SELECT_POI"), WARN)
		return
	if _target.picked_id() == "":
		_say(tr("%%SVC_MSG_NEED_TARGET"), WARN)
		return
	var result: Dictionary = await PlayerServices.poi_transfer(str(poi.get("id", "")),
			_target.picked_kind(), _target.picked_id())
	if _report(result, tr("%%SVC_MSG_POI_TRANSFERRED")):
		_clear_detail()
		refresh()


# ---------------------------------------------------------------------------------------------
# Create / edit form
# ---------------------------------------------------------------------------------------------

func _build_form(page: VBoxContainer) -> void:
	_frameless(page)
	_form_card = _panel(tr("%%SVC_POI_NEW_TITLE"))
	page.add_child(_form_card)
	var rows := _form_card.body
	rows.add_theme_constant_override("separation", 20)

	_form_name = _field(tr("%%SVC_PH_POI_NAME"), 240.0)
	_form_visibility = _option_enum(VISIBILITY_ENTRIES, 150.0)
	var visibility := _form_field(tr("%%SVC_LBL_VISIBILITY"), _form_visibility)
	var name_field := _form_field(tr("%%SVC_LBL_NAME"), _form_name)
	var names := _field_row([name_field, visibility])
	name_field.size_flags_stretch_ratio = 2.0
	rows.add_child(names)

	_form_description = _textarea(tr("%%SVC_PH_POI_DESCRIPTION"), 110.0)
	rows.add_child(_form_field(tr("%%SVC_LBL_DESCRIPTION"), _form_description))

	# Where it is: never typed. The player takes the place they stand in, or picks one on the chart;
	# the form shows what that resolved to and sends exactly that.
	_tile_here = _place_tile(tr("%%SVC_POI_HERE_TITLE"), tr("%%SVC_POI_HERE_SUB"), _take_here)
	_tile_chart = _place_tile(tr("%%SVC_POI_CHART_TITLE"), tr("%%SVC_POI_CHART_SUB"), _take_on_chart)
	var tiles := GridContainer.new()
	tiles.columns = 2
	tiles.add_theme_constant_override("h_separation", 14)
	tiles.add_child(_tile_here)
	tiles.add_child(_tile_chart)
	var place := VBoxContainer.new()
	place.add_theme_constant_override("separation", 10)
	place.add_child(tiles)
	_form_where = _hint(tr("%%SVC_MSG_TAKE_A_PLACE"))
	place.add_child(_form_where)
	rows.add_child(_form_field(tr("%%SVC_LBL_LOCATION"), place))

	# The radius is the one number the player owns: it is only a place until they widen it into a
	# zone, and only then is it worth anything.
	_form_radius = _number_field(tr("%%SVC_PH_ZONE_RADIUS"), 130.0)
	var radius := _form_field(tr("%%SVC_LBL_RADIUS_ZONE"), _suffix_field(_form_radius, "m"))
	var owner_box := VBoxContainer.new()
	owner_box.add_theme_constant_override("separation", 10)
	_form_owner = _option_enum(OWNER_ENTRIES, 170.0)
	_form_owner.item_selected.connect(func(_index: int) -> void: _sync_owner())
	owner_box.add_child(_form_owner)
	_form_owner_picker = ServiceTargetPicker.new()
	_form_owner_picker.setup(ServiceTargetPicker.Mask.CORPORATIONS, true)
	adopt_field(_form_owner_picker.search_field())
	owner_box.add_child(_form_owner_picker)
	rows.add_child(_field_row([radius, _form_field(tr("%%SVC_LBL_OWNER"), owner_box)]))

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rows.add_child(spacer)
	var buttons := _actions_bar()
	buttons.add_child(_spacer())
	var cancel := _action_button(buttons, tr("%%SVC_ACT_CANCEL"), _cancel_form)
	ServiceStyle.apply_button_kind(cancel, ServiceStyle.ButtonKind.GHOST)
	_form_new = _action_button(buttons, tr("%%SVC_ACT_NEW_POI"), _blank_form)
	_form_create = _primary_button(buttons, tr("%%SVC_ACT_CREATE_POI"), _create)
	_form_save = _primary_button(buttons, tr("%%SVC_ACT_SAVE"), _save)
	rows.add_child(buttons)
	_blank_form()


## A place tile (the mock-up's "Ma position actuelle" / "Choisir sur la carte"): a pin badge, a
## title over a muted line; pressing it takes the place that way.
func _place_tile(title: String, sub: String, handler: Callable) -> Button:
	var tile := _item_row({"name": title, "sub": sub})
	tile.custom_minimum_size.y = 84
	_add_pin(tile)
	tile.pressed.connect(handler)
	return tile


## Put the point-of-interest pin badge at the head of an [method _item_row] tile.
func _add_pin(tile: Button) -> void:
	var line := tile.get_child(0) as HBoxContainer
	if line == null:
		return
	var badge := _poi_badge(48.0)
	line.add_child(badge)
	line.move_child(badge, 0)


## The point-of-interest badge: a pin pictogram in an amber-on-dark square.
static func _poi_badge(side: float) -> PanelContainer:
	var thumb := PanelContainer.new()
	thumb.custom_minimum_size = Vector2(side, side)
	thumb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ServiceStyle.apply_thumb(thumb)
	var icon := ServiceAppIcon.new()
	icon.kind = ServiceAppIcon.Kind.POIS
	icon.colour = ServiceStyle.ACCENT
	icon.custom_minimum_size = Vector2.ZERO
	thumb.add_child(icon)
	return thumb


## Light the place tile that says how the place was taken ("" lights none).
func _light_tile(which: String) -> void:
	if _tile_here != null:
		ServiceStyle.apply_tile(_tile_here, which == "here")
	if _tile_chart != null:
		ServiceStyle.apply_tile(_tile_chart, which == "chart")


## Cancel: a blank form again, and back to the list.
func _cancel_form() -> void:
	_blank_form()
	goto_segment(0)


## Prefill the form for an edit. Ownership is read-only in the patch, so the owner select locks.
## The place is not re-typed either: it is read back and shown, and the player moves it only if
## they choose to.
func _fill_form(poi: Dictionary) -> void:
	_edit_id = str(poi.get("id", ""))
	_awaiting_place = false
	_form_card.caption.text = ("%s : %s" % [tr("%%SVC_TAB_EDIT"), ServiceTypes.dash(poi.get("name"))]).to_upper()
	_form_name.text = _text(poi.get("name"))
	_form_description.text = _text(poi.get("description"))
	_placed = {
		"system": _text(poi.get("system")),
		"scene": _text(poi.get("scene")),
		"position": Vector3(ServiceTypes.num(poi.get("x")), ServiceTypes.num(poi.get("y")),
				ServiceTypes.num(poi.get("z"))),
	}
	_render_where()
	_light_tile("")
	_form_radius.text = _coordinate(poi.get("radiusM"))
	_select_enum(_form_visibility, ServiceTypes.dash(poi.get("visibility")))
	_select_enum(_form_owner, "corporation" if poi.get("ownerType") == "corporation" else "")
	_form_owner.disabled = true
	_form_owner_picker.visible = _enum_value(_form_owner) != ""
	_sync_form_buttons()


## The blank form: everything back to its default, ready to create.
func _blank_form() -> void:
	_edit_id = ""
	_awaiting_place = false
	_form_card.caption.text = tr("%%SVC_POI_NEW_TITLE").to_upper()
	_form_name.text = ""
	_form_description.text = ""
	_placed = {}
	_render_where()
	_light_tile("")
	_form_radius.text = ""
	_form_visibility.select(0)
	_form_owner.select(0)
	_form_owner.disabled = false
	_form_owner_picker.visible = false
	_sync_form_buttons()


## Show only the buttons the current mode can act on: a blank form creates, an edit saves. Neither
## state ever offers a button that would do nothing.
func _sync_form_buttons() -> void:
	var editing: bool = _edit_id != ""
	if _form_create != null:
		_form_create.visible = not editing
	if _form_save != null:
		_form_save.visible = editing
	# The blank button only has somewhere to go while an edit is open.
	if _form_new != null:
		_form_new.visible = editing


## Take the place the player stands in right now. No network, no map: the body they are on and
## where on it they are, resolved once and shown.
func _take_here() -> void:
	var player := PlayerLocation.local_player()
	if player == null:
		_say(tr("%%SVC_MSG_NO_PLAYER"), WARN)
		return
	_placed = PlayerLocation.presence_of(player)
	_render_where()
	_light_tile("here")
	_say(tr("%%SVC_MSG_PLACE_HERE"), GOOD)


## Ask the chart for a place: the console owns the chart, so all this does is ask — it opens on the
## NAVIGATION tab in placement mode, the player drops the mission marker there, and it comes back
## through [method set_placed]. Nothing here ever reaches for [StarMap].
##
## The form says it is WAITING before it asks: the place that comes back is handed to the app that
## asked for it, and this form takes it only because it did.
func _take_on_chart() -> void:
	if _placed == null or (_placed as Dictionary).is_empty():
		_take_here()
	_awaiting_place = true
	_light_tile("chart")
	placement_requested.emit(maxf(_coordinate_of(_form_radius.text), 0.0))
	_say(tr("%%SVC_MSG_PICK_ON_CHART"), DIM)


## Show what was resolved: system · scene, then the metres. A form with no place yet says so.
func _render_where() -> void:
	if _form_where == null:
		return
	if _placed == null or (_placed is Dictionary) and (_placed as Dictionary).is_empty():
		_form_where.text = tr("%%SVC_MSG_TAKE_A_PLACE")
		return
	var place: Dictionary = _placed
	var position: Vector3 = place.get("position", Vector3.ZERO) as Vector3
	var head := PackedStringArray()
	if str(place.get("system", "")) != "":
		head.append(str(place["system"]))
	if str(place.get("scene", "")) != "":
		head.append(str(place["scene"]))
	var where: String = " · ".join(head) if head.size() > 0 else "—"
	_form_where.text = "%s  —  %.1f, %.1f, %.1f" % [where, position.x, position.y, position.z]


func _sync_owner() -> void:
	_form_owner_picker.visible = _enum_value(_form_owner) != ""


func _create() -> void:
	release_fields()
	var body := _form_body()
	if body.is_empty():
		return
	var owner := _enum_value(_form_owner)
	if owner != "":
		var owner_id := _form_owner_picker.picked_id()
		if owner_id == "":
			_say(tr("%%SVC_MSG_NEED_CORP_ID"), WARN)
			return
		body["owner"] = {"type": owner, "id": owner_id}
	var result: Dictionary = await PlayerServices.poi_create(body)
	if _report(result, tr("%%SVC_MSG_POI_CREATED")):
		_blank_form()
		refresh()


func _save() -> void:
	release_fields()
	if _edit_id == "":
		_say(tr("%%SVC_MSG_SELECT_POI"), WARN)
		return
	var body := _form_body()
	if body.is_empty():
		return
	var result: Dictionary = await PlayerServices.poi_update(_edit_id, body)
	if _report(result, tr("%%SVC_MSG_POI_UPDATED")):
		refresh()


## The fields both create and update send. An empty dictionary means a required field is missing,
## and the player has already been told which one on the status line.
func _form_body() -> Dictionary:
	var poi_name := _form_name.text.strip_edges()
	if poi_name == "":
		_say(tr("%%SVC_MSG_POI_NAME_REQUIRED"), WARN)
		return {}
	if _placed == null or (_placed as Dictionary).is_empty() or not (_placed as Dictionary).has("position"):
		_say(tr("%%SVC_MSG_TAKE_A_PLACE"), WARN)
		return {}
	var place: Dictionary = _placed
	var position: Vector3 = place.get("position", Vector3.ZERO) as Vector3
	var body := {
		"name": poi_name,
		"x": position.x,
		"y": position.y,
		"z": position.z,
		"visibility": _enum_value(_form_visibility),
	}
	var description: String = _form_description.text.strip_edges()
	if description != "":
		body["description"] = description
	for pair: Array in [
		["system", str(place.get("system", ""))],
		["scene", str(place.get("scene", ""))],
	]:
		if str(pair[1]) != "":
			body[pair[0]] = str(pair[1])
	var radius := _form_radius.text.strip_edges()
	if radius.is_valid_float():
		body["radiusM"] = _coordinate_of(radius)
	return body


## The chart handed a place over: what the player picked is now where the form says it is.
## Called by PlayerClient, which owns the chart (this file never reaches for [StarMap]).
##
## Answers true only for a place THIS form asked for: several forms can have the chart open, and a
## mission builder's marker is not this form's place to take — taking it anyway is what used to send
## the player to the inventory instead of back to their mission.
func set_placed(place: Dictionary) -> bool:
	if place.is_empty() or not place.has("position"):
		return false
	if not _awaiting_place:
		return false
	_awaiting_place = false
	_placed = place.duplicate()
	_render_where()
	# What the map sized the marker at is what the form now says. The field is the radius this POI is
	# about to be created with, and the wheel on the chart is where it was last true; an empty field
	# is a point, which is what a marker wheeled down to none means.
	if place.has("radiusM") and _form_radius != null:
		var radius: int = int(ServiceTypes.num(place.get("radiusM")))
		_form_radius.text = "" if radius <= 0 else str(radius)
	_say(tr("%%SVC_MSG_PLACE_CHART"), GOOD)
	return true


# ---------------------------------------------------------------------------------------------
# Corporation tab
# ---------------------------------------------------------------------------------------------

func _build_corp(page: VBoxContainer) -> void:
	_frameless(page)
	# No corporation: the mock-up's empty state, and the way to join or found one.
	_corp_empty = _panel()
	(_corp_empty as Card).body.add_child(_empty_state(tr("%%SVC_POI_CORP_NONE"), tr("%%SVC_POI_CORP_NONE_TEXT"),
			tr("%%SVC_POI_CORP_JOIN"), func() -> void: open_app_requested.emit("social", 2, -1)))
	page.add_child(_corp_empty)

	_corp_columns = _columns()
	page.add_child(_corp_columns)
	_page_corp_pois = ServicePage.new()
	_page_corp_pois.load_requested.connect(_load_corp_pois)
	_corp_pois = RowList.new()
	_corp_pois.row_selected.connect(func(_meta: Variant) -> void: _load_corp_detail())
	_corp_pois_card = _panel(tr("%%SVC_APP_POIS"), "0")
	# Which of the player's corporations: one chip each (hidden when there is only one).
	_corp_bar_box = HBoxContainer.new()
	_corp_pois_card.body.add_child(_corp_bar_box)
	_corp_pois_empty = _empty_state(tr("%%SVC_MSG_NO_POIS"), tr("%%SVC_POI_CORP_NONE_TEXT"))
	_corp_pois_scroll = _list_body(_corp_pois_card, _corp_pois, _corp_pois_empty, _page_corp_pois)
	_corp_columns.add_child(_fixed(_corp_pois_card, LIST_WIDTH))
	var detail := _panel(tr("%%SVC_LBL_DETAIL"))
	_corp_detail_box = detail.body
	_detail_message(_corp_detail_box, tr("%%SVC_MSG_SELECT_POI"))
	_corp_columns.add_child(detail)
	_show_corps()


## The player's corporations, read again: the tab shows the empty state without one, else the
## points of the one picked (the first by default).
func _load_corps() -> void:
	var result: Dictionary = await PlayerServices.my_corporations(20)
	_corps = []
	if bool(result.get("ok", false)):
		for entry: Dictionary in ServicePage.items_of(result):
			var corporation_id := str(entry.get("id", entry.get("corporationId", "")))
			if corporation_id != "":
				_corps.append({"id": corporation_id,
						"name": str(entry.get("displayName", entry.get("name", corporation_id)))})
	var known: bool = false
	for corp: Dictionary in _corps:
		known = known or corp["id"] == _corp_id
	if not known:
		_corp_id = str(_corps[0]["id"]) if not _corps.is_empty() else ""
	_show_corps()
	if _corp_id != "":
		_page_corp_pois.reset()


## Empty state or list, and the chips of the corporations when there is more than one.
func _show_corps() -> void:
	_corp_empty.visible = _corps.is_empty()
	_corp_columns.visible = not _corps.is_empty()
	_clear(_corp_bar_box)
	if _corps.size() > 1:
		var entries: Array = []
		for corp: Dictionary in _corps:
			entries.append([corp["id"], corp["name"]])
		_corp_bar_box.add_child(_choice_bar(entries, _corp_id, _pick_corp))
	_corp_bar_box.visible = _corps.size() > 1


func _pick_corp(corporation_id: String) -> void:
	_corp_id = corporation_id
	_detail_message(_corp_detail_box, tr("%%SVC_MSG_SELECT_POI"))
	# Another corporation is another list: back to its first window, which loads it.
	_page_corp_pois.reset()


func _load_corp_pois() -> void:
	var corporation_id := _corp_id
	if corporation_id == "":
		return
	var at: int = _page_corp_pois.offset
	var result: Dictionary = await PlayerServices.corporation_pois(corporation_id,
			_page_corp_pois.limit, at)
	if _land(_page_corp_pois, at, result):
		_apply_pois(_page_corp_pois, result, _corp_pois, _corp_pois_card, _corp_pois_empty, _corp_pois_scroll)


func _load_corp_detail() -> void:
	var corporation_id := _corp_id
	var poi: Dictionary = _selected_poi(_corp_pois)
	if corporation_id == "" or poi.is_empty():
		return
	var result: Dictionary = await PlayerServices.corporation_poi(corporation_id,
			str(poi.get("id", "")))
	if not bool(result.get("ok", false)):
		_detail_message(_corp_detail_box, HttpClient.describe_error(result), WARN)
		return
	_render_detail(_corp_detail_box, _as_poi(result.get("data")), false)


# ---------------------------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------------------------

## Fill a POI list from a list response — the caller's scope and a corporation's scope share it.
## The panel's count follows the window's total; the empty state stands in for no rows.
func _apply_pois(page: ServicePage, result: Dictionary, list: RowList, card: Card, empty: Control,
		scroll: Control) -> void:
	if not bool(result.get("ok", false)):
		list.set_rows([{"name": tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", "")), "meta": null}])
		empty.visible = false
		scroll.visible = true
		return
	var rows: Array = []
	for poi: Dictionary in page.rows(result):
		rows.append({
			"name": ServiceTypes.dash(poi.get("name")),
			"sub": ServiceTypes.poi_location(poi),
			"value": ServiceTypes.poi_visibility_label(poi.get("visibility")),
			"value_colour": ServiceStyle.MUTED,
			"meta": poi,
		})
	list.set_rows(rows)
	for i: int in range(list.get_child_count()):
		_add_pin(list.get_child(i) as Button)
	card.set_count(str(page.total))
	empty.visible = rows.is_empty()
	scroll.visible = not rows.is_empty()


## The selected row as a POI object ({} when the row is only an error line, or nothing is picked).
func _selected_poi(list: RowList) -> Dictionary:
	return _as_poi(list.selected_meta())


## Re-select the row carrying [param poi_id] after a refresh rebuilt the list (it reopens its detail).
## Returns whether it was found.
func _select_poi(list: RowList, poi_id: String) -> bool:
	if poi_id == "":
		return false
	return list.select_where(func(meta: Variant) -> bool: return _as_poi(meta).get("id", "") == poi_id)


func _clear_detail() -> void:
	_detail_id = ""
	_detail_message(_detail_box, tr("%%SVC_MSG_SELECT_POI"))
	_fill_shares([])


## Select the [OptionButton] row whose metadata is [param value] (first row when it is unknown).
func _select_enum(option: OptionButton, value: String) -> void:
	for index: int in range(option.item_count):
		if str(option.get_item_metadata(index)) == value:
			option.select(index)
			return
	option.select(0)


## A payload that should be a POI, or an empty one when the service answered something else.
static func _as_poi(value: Variant) -> Dictionary:
	if value is Dictionary:
		return value as Dictionary
	return {}


## A payload string: null becomes "", never the literal "<null>" a plain str() would show.
static func _text(value: Variant) -> String:
	return "" if value == null else str(value)


## A coordinate as the form writes it: trimmed, and empty when the POI has no value there.
static func _coordinate(value: Variant) -> String:
	if value == null:
		return ""
	return str(value)


## A form coordinate as the payload sends it.
static func _coordinate_of(raw: String) -> float:
	return raw.strip_edges().to_float()
