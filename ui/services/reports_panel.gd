extends ServicePanel

## App « Signalements » : file a report against a player or a corporation, and review the ones already
## filed. Covers POST/GET /api/reports.

const TARGET_TYPE_ENTRIES: Array = [
	["player", "%%SVC_ENUM_REPORT_TARGET_PLAYER"],
	["corporation", "%%SVC_ENUM_REPORT_TARGET_CORPORATION"],
]
const REASON_ENTRIES: Array = [
	["harassment", "%%SVC_ENUM_REASON_HARASSMENT"],
	["cheating", "%%SVC_ENUM_REASON_CHEATING"],
	["griefing", "%%SVC_ENUM_REASON_GRIEFING"],
	["offensive_name", "%%SVC_ENUM_REASON_OFFENSIVE_NAME"],
	["scam", "%%SVC_ENUM_REASON_SCAM"],
	["other", "%%SVC_ENUM_REASON_OTHER"],
]

var _reports: ItemList
var _target_type: OptionButton
var _target_id: LineEdit
var _reason: OptionButton
var _message: LineEdit


func _build() -> void:
	var bar := _app_bar(tr("%%SVC_APP_REPORTS"), ServiceAppIcon.Kind.REPORTS)
	_action_button(bar, tr("%%SVC_ACT_REFRESH"), func() -> void: refresh())
	add_child(bar)

	var pages := _segments_pages(PackedStringArray([
			tr("%%SVC_TAB_REPORT"), tr("%%SVC_TAB_MY_REPORTS")]))
	_build_report_page(pages[0])
	_build_history_page(pages[1])
	add_child(_status_line())


func _build_report_page(page: VBoxContainer) -> void:
	var form := VBoxContainer.new()
	form.add_theme_constant_override("separation", 10)
	_target_type = _option_enum(TARGET_TYPE_ENTRIES)
	_target_id = _field(tr("%%SVC_PH_TARGET_ID"), 320.0)
	_reason = _option_enum(REASON_ENTRIES)
	_message = _field(tr("%%SVC_PH_MESSAGE_OPTIONAL"), 360.0)
	form.add_child(_label(tr("%%SVC_LBL_TARGET_TYPE"), DIM))
	form.add_child(_target_type)
	form.add_child(_label(tr("%%SVC_LBL_IDENTIFIER"), DIM))
	form.add_child(_target_id)
	form.add_child(_label(tr("%%SVC_LBL_REASON"), DIM))
	form.add_child(_reason)
	form.add_child(_label(tr("%%SVC_LBL_MESSAGE"), DIM))
	form.add_child(_message)
	_action_button(form, tr("%%SVC_ACT_SEND_REPORT"), func() -> void: _create_report())
	page.add_child(_titled(tr("%%SVC_LBL_NEW_REPORT"), form))


func _build_history_page(page: VBoxContainer) -> void:
	_reports = _list(280.0)
	page.add_child(_titled(tr("%%SVC_LBL_MY_REPORTS"), _reports, true))


func refresh() -> void:
	if not _begin_refresh():
		return
	var reports: Dictionary = await PlayerServices.reports_list()
	_apply_reports(reports)
	_end_refresh()


func _apply_reports(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(_reports, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	for report: Dictionary in (result.get("data", []) if result.get("data") is Array else []):
		lines.append(ServiceTypes.report_line(report))
		metadata.append(report)
	if lines.is_empty():
		lines.append(tr("%%SVC_MSG_NO_REPORTS"))
	_fill_list(_reports, lines, metadata)


func _create_report() -> void:
	release_fields()
	var target_id: String = _target_id.text.strip_edges()
	if target_id == "":
		_say(tr("%%SVC_MSG_NEED_TARGET"), WARN)
		return
	var target_type: String = _enum_value(_target_type) if _target_type != null else "player"
	var reason: String = _enum_value(_reason) if _reason != null else "other"
	var result: Dictionary = await PlayerServices.report_create(target_type, target_id, reason,
			_message.text.strip_edges())
	if _report(result, tr("%%SVC_MSG_REPORT_SENT")):
		_target_id.text = ""
		_message.text = ""
		refresh()
