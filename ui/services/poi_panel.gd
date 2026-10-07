extends ServicePanel

## App « Points of interest » : the POIs of the caller's scope (owned, read-only grants, public),
## the detail of one POI with its grants, the create/edit form, and a corporation's POIs. Covers
## /api/me/pois* and /api/corporations/{corporationId}/pois*.

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

## My POIs, the detail of the selected one, its grants, and the picker that names a grantee.
var _pois: ItemList
var _page_pois: ServicePage
var _detail: Label
var _shares: ItemList
var _target: ServiceTargetPicker
## The id whose detail is open, so a refresh can restore the selection it wiped.
var _detail_id: String = ""
## The form, and the id it edits ("" = a blank form, ready to create).
var _form_mode: Label
var _form_name: LineEdit
var _form_description: TextEdit
var _form_system: LineEdit
var _form_scene: LineEdit
var _form_x: LineEdit
var _form_y: LineEdit
var _form_z: LineEdit
var _form_radius: LineEdit
var _form_visibility: OptionButton
var _form_owner: OptionButton
var _form_owner_picker: ServiceTargetPicker
var _edit_id: String = ""
## The corporation tab.
var _corp_picker: ServiceTargetPicker
var _corp_pois: ItemList
var _page_corp_pois: ServicePage
var _corp_detail: Label


func _build() -> void:
	var bar := _app_bar(tr("%%SVC_APP_POIS"), ServiceAppIcon.Kind.POIS)
	_action_button(bar, tr("%%SVC_ACT_REFRESH"), func() -> void: refresh())
	add_child(bar)

	var pages := _segments_pages(PackedStringArray([
			tr("%%SVC_TAB_MY_POIS"), tr("%%SVC_TAB_CREATE"), tr("%%SVC_TAB_CORP_POIS")]))
	_build_mine(pages[0])
	_build_form(pages[1])
	_build_corp(pages[2])
	add_child(_status_line())


func refresh() -> void:
	if not _begin_refresh():
		return
	var open_id := _detail_id
	await _load_pois()
	if _select_poi(_pois, open_id):
		await _load_detail()
	_end_refresh()


func _load_pois() -> void:
	var at: int = _page_pois.offset
	var result: Dictionary = await PlayerServices.poi_list(_page_pois.limit, at)
	if _land(_page_pois, at, result):
		_apply_pois(_page_pois, result, _pois, tr("%%SVC_MSG_NO_POIS"))


# ---------------------------------------------------------------------------------------------
# My POIs — list, detail, grants
# ---------------------------------------------------------------------------------------------

func _build_mine(page: VBoxContainer) -> void:
	var columns := _row(18)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_page_pois = ServicePage.new()
	_page_pois.load_requested.connect(_load_pois)
	_pois = _paged_list(columns, tr("%%SVC_APP_POIS"), _page_pois, 240.0)
	_pois.item_selected.connect(func(_i: int) -> void: _load_detail())

	var side := VBoxContainer.new()
	side.add_theme_constant_override("separation", 12)
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail = _label(tr("%%SVC_MSG_SELECT_POI"), DIM)
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_titled(tr("%%SVC_LBL_DETAIL"), _detail, true))
	_shares = _list(130.0)
	side.add_child(_titled(tr("%%SVC_LBL_SHARES"), _shares, true))
	columns.add_child(side)
	page.add_child(columns)

	# These act on the selected POI: the grant list feeds the revoke, the picker the other two.
	var selection := _row()
	_action_button(selection, tr("%%SVC_ACT_EDIT"), _edit_selected)
	_action_button(selection, tr("%%SVC_ACT_DELETE_POI"), _delete_selected)
	page.add_child(selection)

	_target = ServiceTargetPicker.new()
	_target.setup(ServiceTargetPicker.Mask.EITHER, true)
	adopt_field(_target.search_field())
	page.add_child(_titled(tr("%%SVC_LBL_RECIPIENT"), _target))

	var grants := _row()
	_action_button(grants, tr("%%SVC_ACT_GRANT"), _grant)
	_action_button(grants, tr("%%SVC_ACT_REVOKE"), _revoke)
	_action_button(grants, tr("%%SVC_ACT_TRANSFER"), _transfer)
	page.add_child(grants)


## Open the detail and the grants of the row the player picked.
func _load_detail() -> void:
	var poi: Dictionary = _selected_poi(_pois)
	if poi.is_empty():
		return
	var result: Dictionary = await PlayerServices.poi_get(str(poi.get("id", "")))
	if not bool(result.get("ok", false)):
		_detail.text = HttpClient.describe_error(result)
		return
	if not (result.get("data") is Dictionary):
		_detail.text = tr("%%SVC_MSG_UNEXPECTED")
		return
	var view: Dictionary = result.get("data")
	_detail_id = str(view.get("id", ""))
	_detail.text = ServiceTypes.poi_detail(view)
	_fill_shares(view.get("shares"))


func _fill_shares(value: Variant) -> void:
	var lines := PackedStringArray()
	var metadata: Array = []
	for share: Dictionary in (value if value is Array else []):
		lines.append(ServiceTypes.poi_share_line(share))
		metadata.append(share)
	if lines.is_empty():
		lines.append(tr("%%SVC_MSG_NONE"))
	_fill_list(_shares, lines, metadata)


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
	var share: Variant = _selected_meta(_shares)
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
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 10)
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_form_mode = _label(tr("%%SVC_TAB_CREATE"), ServiceStyle.ACCENT)
	rows.add_child(_form_mode)

	var names := _row(10)
	names.add_child(_label(tr("%%SVC_LBL_NAME"), DIM))
	_form_name = _field(tr("%%SVC_PH_POI_NAME"), 240.0)
	names.add_child(_form_name)
	names.add_child(_label(tr("%%SVC_LBL_VISIBILITY"), DIM))
	_form_visibility = _option_enum(VISIBILITY_ENTRIES, 150.0)
	names.add_child(_form_visibility)
	rows.add_child(names)

	rows.add_child(_label(tr("%%SVC_LBL_DESCRIPTION"), DIM))
	_form_description = _textarea(tr("%%SVC_PH_POI_DESCRIPTION"), 90.0)
	rows.add_child(_form_description)

	# The location fields carry the mission-zone wording: same values, same meaning.
	var where := _row(10)
	_form_system = _field(tr("%%SVC_PH_ZONE_SYSTEM"), 170.0)
	_form_scene = _field(tr("%%SVC_PH_ZONE_SCENE"), 190.0)
	where.add_child(_form_system)
	where.add_child(_form_scene)
	rows.add_child(where)

	var position := _row(10)
	_form_x = _number_field(tr("%%SVC_PH_ZONE_X"), 90.0)
	_form_y = _number_field(tr("%%SVC_PH_ZONE_Y"), 90.0)
	_form_z = _number_field(tr("%%SVC_PH_ZONE_Z"), 90.0)
	_form_radius = _number_field(tr("%%SVC_PH_ZONE_RADIUS"), 130.0)
	position.add_child(_form_x)
	position.add_child(_form_y)
	position.add_child(_form_z)
	position.add_child(_form_radius)
	rows.add_child(position)

	var owner := _row(10)
	owner.add_child(_label(tr("%%SVC_LBL_OWNER"), DIM))
	_form_owner = _option_enum(OWNER_ENTRIES, 170.0)
	_form_owner.item_selected.connect(func(_index: int) -> void: _sync_owner())
	owner.add_child(_form_owner)
	_form_owner_picker = ServiceTargetPicker.new()
	_form_owner_picker.setup(ServiceTargetPicker.Mask.CORPORATIONS, true)
	adopt_field(_form_owner_picker.search_field())
	owner.add_child(_form_owner_picker)
	rows.add_child(owner)

	var buttons := _row()
	_action_button(buttons, tr("%%SVC_ACT_NEW_POI"), _blank_form)
	_action_button(buttons, tr("%%SVC_ACT_CREATE_POI"), _create)
	_action_button(buttons, tr("%%SVC_ACT_SAVE"), _save)
	rows.add_child(buttons)

	page.add_child(rows)
	_blank_form()


## Prefill the form for an edit. Ownership is read-only in the patch, so the owner select locks.
func _fill_form(poi: Dictionary) -> void:
	_edit_id = str(poi.get("id", ""))
	_form_mode.text = "%s : %s" % [tr("%%SVC_TAB_EDIT"), ServiceTypes.dash(poi.get("name"))]
	_form_name.text = _text(poi.get("name"))
	_form_description.text = _text(poi.get("description"))
	_form_system.text = _text(poi.get("system"))
	_form_scene.text = _text(poi.get("scene"))
	_form_x.text = _coordinate(poi.get("x"))
	_form_y.text = _coordinate(poi.get("y"))
	_form_z.text = _coordinate(poi.get("z"))
	_form_radius.text = _coordinate(poi.get("radiusM"))
	_select_enum(_form_visibility, ServiceTypes.dash(poi.get("visibility")))
	_select_enum(_form_owner, "corporation" if poi.get("ownerType") == "corporation" else "")
	_form_owner.disabled = true
	_form_owner_picker.visible = _enum_value(_form_owner) != ""


## The blank form: everything back to its default, ready to create.
func _blank_form() -> void:
	_edit_id = ""
	_form_mode.text = tr("%%SVC_TAB_CREATE")
	_form_name.text = ""
	_form_description.text = ""
	_form_system.text = ""
	_form_scene.text = ""
	_form_x.text = ""
	_form_y.text = ""
	_form_z.text = ""
	_form_radius.text = ""
	_form_visibility.select(0)
	_form_owner.select(0)
	_form_owner.disabled = false
	_form_owner_picker.visible = false


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
	var coordinates := [_form_x.text.strip_edges(), _form_y.text.strip_edges(),
		_form_z.text.strip_edges()]
	for coordinate: String in coordinates:
		if not coordinate.is_valid_float():
			_say(tr("%%SVC_MSG_POI_COORDINATES"), WARN)
			return {}
	var body := {
		"name": poi_name,
		"x": _coordinate_of(coordinates[0]),
		"y": _coordinate_of(coordinates[1]),
		"z": _coordinate_of(coordinates[2]),
		"visibility": _enum_value(_form_visibility),
	}
	for pair: Array in [
		["description", _form_description.text.strip_edges()],
		["system", _form_system.text.strip_edges()],
		["scene", _form_scene.text.strip_edges()],
	]:
		if str(pair[1]) != "":
			body[pair[0]] = str(pair[1])
	var radius := _form_radius.text.strip_edges()
	if radius.is_valid_float():
		body["radiusM"] = _coordinate_of(radius)
	return body


# ---------------------------------------------------------------------------------------------
# Corporation tab
# ---------------------------------------------------------------------------------------------

func _build_corp(page: VBoxContainer) -> void:
	var picker_row := _row()
	_corp_picker = ServiceTargetPicker.new()
	_corp_picker.setup(ServiceTargetPicker.Mask.CORPORATIONS, true)
	adopt_field(_corp_picker.search_field())
	picker_row.add_child(_corp_picker)
	_action_button(picker_row, tr("%%SVC_ACT_LOAD"), _load_corp)
	page.add_child(picker_row)

	var columns := _row(18)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_page_corp_pois = ServicePage.new()
	_page_corp_pois.load_requested.connect(_load_corp_pois)
	_corp_pois = _paged_list(columns, tr("%%SVC_APP_POIS"), _page_corp_pois, 240.0)
	_corp_pois.item_selected.connect(func(_i: int) -> void: _load_corp_detail())
	_corp_detail = _label(tr("%%SVC_MSG_SELECT_POI"), DIM)
	_corp_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	columns.add_child(_titled(tr("%%SVC_LBL_DETAIL"), _corp_detail, true))
	page.add_child(columns)


func _load_corp() -> void:
	release_fields()
	var corporation_id := _corp_picker.picked_id()
	if corporation_id == "":
		_say(tr("%%SVC_MSG_NEED_CORP_ID"), WARN)
		return
	# Another corporation is another list: back to its first window, which loads it.
	_page_corp_pois.reset()


func _load_corp_pois() -> void:
	var corporation_id := _corp_picker.picked_id()
	if corporation_id == "":
		return
	var at: int = _page_corp_pois.offset
	var result: Dictionary = await PlayerServices.corporation_pois(corporation_id,
			_page_corp_pois.limit, at)
	if _land(_page_corp_pois, at, result):
		_apply_pois(_page_corp_pois, result, _corp_pois, tr("%%SVC_MSG_NO_POIS"))


func _load_corp_detail() -> void:
	var corporation_id := _corp_picker.picked_id()
	var poi: Dictionary = _selected_poi(_corp_pois)
	if corporation_id == "" or poi.is_empty():
		return
	var result: Dictionary = await PlayerServices.corporation_poi(corporation_id,
			str(poi.get("id", "")))
	if not bool(result.get("ok", false)):
		_corp_detail.text = HttpClient.describe_error(result)
		return
	var data: Variant = result.get("data")
	_corp_detail.text = ServiceTypes.poi_detail(_as_poi(data))


# ---------------------------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------------------------

## Fill a POI list from a list response — the caller's scope and a corporation's scope share it.
func _apply_pois(page: ServicePage, result: Dictionary, list: ItemList, empty: String) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(list, PackedStringArray([
				tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	for poi: Dictionary in page.rows(result):
		lines.append(ServiceTypes.poi_line(poi))
		metadata.append(poi)
	if lines.is_empty():
		lines.append(empty)
	_fill_list(list, lines, metadata)


## The selected row as a POI object ({} when the row is only an error line, or nothing is picked).
func _selected_poi(list: ItemList) -> Dictionary:
	return _as_poi(_selected_meta(list))


## Re-select the row carrying [param poi_id] after a refresh cleared the list. Returns whether it
## was found: the caller then reloads the detail that was open.
func _select_poi(list: ItemList, poi_id: String) -> bool:
	if poi_id == "":
		return false
	for index: int in range(list.item_count):
		var meta: Variant = list.get_item_metadata(index)
		if meta is Dictionary and str((meta as Dictionary).get("id", "")) == poi_id:
			list.select(index)
			return true
	return false


func _clear_detail() -> void:
	_detail_id = ""
	_detail.text = tr("%%SVC_MSG_SELECT_POI")
	_fill_list(_shares, PackedStringArray([tr("%%SVC_MSG_NONE")]))


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
