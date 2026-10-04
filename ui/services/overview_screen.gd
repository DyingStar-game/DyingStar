class_name ServiceOverviewScreen
extends VBoxContainer

## The tablet's default content pane: a dashboard of the player's key facts (identity, main account,
## pending requests, active missions). Shown until an app is opened; refreshed on open and on every
## mutation.

var _name_label: Label
var _sub_label: Label
var _balance_label: Label
var _requests_value: Label
var _missions_value: Label
var _busy: bool = false


func setup() -> void:
	add_theme_constant_override("separation", 18)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var title := Label.new()
	title.text = tr("%%SVC_OVERVIEW_TITLE")
	title.add_theme_color_override("font_color", ServiceStyle.TEXT)
	ServiceStyle.font_of(title, 24, true)
	add_child(title)

	add_child(_identity_card())
	add_child(_stat_row())

	var hint := Label.new()
	hint.text = tr("%%SVC_OVERVIEW_HINT")
	hint.add_theme_color_override("font_color", ServiceStyle.MUTED)
	ServiceStyle.font_of(hint, 14)
	add_child(hint)


func _stat_row() -> Control:
	var stats := HBoxContainer.new()
	stats.add_theme_constant_override("separation", 16)
	var requests: Array = _stat_card(tr("%%SVC_OVERVIEW_CAP_REQUESTS"))
	_requests_value = requests[1]
	stats.add_child(requests[0])
	var missions: Array = _stat_card(tr("%%SVC_OVERVIEW_CAP_MISSIONS"))
	_missions_value = missions[1]
	stats.add_child(missions[0])
	return stats


func _identity_card() -> Control:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel",
			ServiceStyle.flat(ServiceStyle.PANEL, ServiceStyle.RADIUS, ServiceStyle.BORDER, 1, 22.0, 18.0))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	card.add_child(row)

	var identity := VBoxContainer.new()
	identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	identity.add_theme_constant_override("separation", 4)
	_name_label = Label.new()
	_name_label.text = "—"
	_name_label.add_theme_color_override("font_color", ServiceStyle.TEXT)
	ServiceStyle.font_of(_name_label, 26, true)
	identity.add_child(_name_label)
	_sub_label = Label.new()
	_sub_label.text = ""
	_sub_label.add_theme_color_override("font_color", ServiceStyle.MUTED)
	ServiceStyle.font_of(_sub_label, 15)
	identity.add_child(_sub_label)
	row.add_child(identity)

	var balance := VBoxContainer.new()
	balance.alignment = BoxContainer.ALIGNMENT_CENTER
	var caption := Label.new()
	caption.text = tr("%%SVC_OVERVIEW_CAP_ACCOUNT")
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	caption.add_theme_color_override("font_color", ServiceStyle.MUTED)
	ServiceStyle.font_of(caption, 12, true)
	balance.add_child(caption)
	_balance_label = Label.new()
	_balance_label.text = "—"
	_balance_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_balance_label.add_theme_color_override("font_color", ServiceStyle.ACCENT)
	ServiceStyle.font_of(_balance_label, 34, true)
	balance.add_child(_balance_label)
	row.add_child(balance)
	return card


## A stat card; returns [card, value_label] so the caller keeps a handle on the value.
func _stat_card(caption: String) -> Array:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel",
			ServiceStyle.flat(ServiceStyle.PANEL_ALT, ServiceStyle.RADIUS, ServiceStyle.BORDER, 1, 18.0, 14.0))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var caption_label := Label.new()
	caption_label.text = caption
	caption_label.add_theme_color_override("font_color", ServiceStyle.MUTED)
	ServiceStyle.font_of(caption_label, 12, true)
	box.add_child(caption_label)
	var value := Label.new()
	value.text = "—"
	value.add_theme_color_override("font_color", ServiceStyle.TEXT)
	ServiceStyle.font_of(value, 30, true)
	box.add_child(value)
	card.add_child(box)
	return [card, value]


func refresh() -> void:
	if _busy:
		return
	_busy = true
	var profile: Dictionary = await PlayerServices.profile_get()
	var wallet: Dictionary = await PlayerServices.wallet()
	var requests: Dictionary = await PlayerServices.friend_requests()
	var missions: Dictionary = await PlayerServices.my_missions("active")
	_apply(profile, wallet, requests, missions)
	_busy = false


func _apply(profile: Dictionary, wallet: Dictionary, requests: Dictionary, missions: Dictionary) -> void:
	if bool(profile.get("ok", false)) and profile.get("data") is Dictionary:
		var me: Dictionary = profile.get("data")
		_name_label.text = str(me.get("displayName", "—"))
		var bits := PackedStringArray()
		var corporations: Variant = me.get("corporations")
		var corporation_found: bool = false
		if corporations is Array:
			for reference: Variant in corporations:
				if reference is Dictionary:
					bits.append(ServiceTypes.corporation_ref_line(reference))
					corporation_found = true
		if not corporation_found:
			bits.append(tr("%%SVC_MSG_NO_CORPORATION"))
		var group: Variant = me.get("group")
		if group is Dictionary:
			bits.append(ServiceTypes.dash((group as Dictionary).get("name")))
		bits.append(tr("%%SVC_FMT_REPUTATION") % ServiceTypes.num(me.get("reputation")))
		_sub_label.text = "   ·   ".join(bits)
	else:
		_name_label.text = tr("%%SVC_MSG_PROFILE_UNAVAILABLE")
		_sub_label.text = str(profile.get("error", ""))

	if bool(wallet.get("ok", false)):
		var accounts: Variant = (wallet.get("data") as Dictionary).get("accounts") \
				if wallet.get("data") is Dictionary else wallet.get("data")
		_balance_label.text = "%s" % Globals.format_thousands(_main_balance(accounts))
	else:
		_balance_label.text = "—"

	if bool(requests.get("ok", false)) and requests.get("data") is Dictionary:
		var incoming: Variant = (requests.get("data") as Dictionary).get("incoming", [])
		_requests_value.text = "%d" % ((incoming as Array).size() if incoming is Array else 0)
	else:
		_requests_value.text = "?"
	if bool(missions.get("ok", false)):
		var data: Variant = missions.get("data")
		var list: Variant = (data as Dictionary).get("missions") if data is Dictionary else data
		_missions_value.text = "%d" % ((list as Array).size() if list is Array else 0)
	else:
		_missions_value.text = "?"


## The player's credits balance, or the first account when there is no `credits` one.
static func _main_balance(accounts: Variant) -> int:
	if not (accounts is Array):
		return 0
	var first: int = 0
	var seen: bool = false
	for account: Dictionary in accounts:
		if not seen:
			first = ServiceTypes.num(account.get("balance"))
			seen = true
		if str(account.get("currency", "")) == "credits":
			return ServiceTypes.num(account.get("balance"))
	return first
