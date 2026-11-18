extends GutTest
## The in-game bug report (F9): what the form accepts, what the report carries, and what never leaves
## the machine. The sending itself is service-social's (its own tests): here, a report is built.


func test_the_key_is_an_action_filed_with_the_captures() -> void:
	InputMap.load_from_project_settings()
	assert_true(InputMap.has_action(&"bug_report"), "a key of the InputMap, rebindable")
	var gallery: Dictionary = MenuConfig.ACTION_GROUPS["%%KM_GROUP_GENERAL"]["%%KM_SECTION_GALLERY"]
	assert_eq(gallery.get("bug_report"), "%%ACT_BUG_REPORT", "listed in Settings > Controls, with F7 and F8")


## A report on the QA team's template, every part filled in.
const FILLED := {
	"title": "Stuck in the truck",
	"description": "Teleporting from the driver's seat freezes me.",
	"steps": "1. Sit at the wheel\n2. Use the teleporter",
	"actual": "Cannot walk nor look around",
	"expected": "Arriving at the wheel",
}


func _typed(changes: Dictionary) -> Dictionary:
	var typed: Dictionary = FILLED.duplicate()
	typed.merge(changes, true)
	return typed


## The template: a title, then the description, the steps, the actual and the expected result.
func test_the_template_is_the_qa_team_s_and_every_part_is_asked() -> void:
	var keys: Array = BugReportDialog.PARTS.map(func(part: Dictionary) -> String: return part["key"])
	assert_eq(keys, ["description", "steps", "actual", "expected"])
	assert_eq(BugReportDialog.problem(FILLED), {}, "all filled in: good to send")
	assert_eq(BugReportDialog.problem(_typed({"title": "  a  "})).get("key"), "%%BUG_REPORT_TITLE_SHORT",
			"spaces do not count")
	for part: Dictionary in BugReportDialog.PARTS:
		var empty: Dictionary = BugReportDialog.problem(_typed({part["key"]: "   "}))
		assert_eq(empty.get("key"), "%%BUG_REPORT_PART_EMPTY", "%s left empty" % part["key"])
		assert_eq(empty.get("label"), part["label"], "and the form names it")
		var long: Dictionary = BugReportDialog.problem(_typed({part["key"]: "x".repeat(int(part["max"]) + 1)}))
		assert_eq(long.get("key"), "%%BUG_REPORT_PART_LONG", "%s too long" % part["key"])
	assert_eq(BugReportDialog.problem(_typed({"steps": "", "expected": ""})).get("label"), "%%BUG_REPORT_STEPS",
			"the first part missing, in the template's order")


## The four parts go out as one Discord message of 4096 characters at most, their headings included.
func test_the_four_parts_fit_one_discord_message() -> void:
	var room: int = 0
	for part: Dictionary in BugReportDialog.PARTS:
		room += int(part["max"])
	assert_lte(room, 3900, "the texts, with room left for the four headings")


func test_the_form_sends_cleaned_texts_and_says_what_is_wrong() -> void:
	var form := BugReportDialog.new()
	add_child_autofree(form)
	watch_signals(form)
	form.open_with(null)
	assert_true(form.is_open())
	form._title.text = "  Stuck in the truck "
	for key: String in ["description", "steps", "actual"]:
		(form._fields[key] as TextEdit).text = "  %s\n" % FILLED[key]
	form._submit()
	assert_signal_not_emitted(form, "submitted", "the expected result is missing: not sent")
	assert_ne(form._status.text, "", "and the form says which part")
	(form._fields["expected"] as TextEdit).text = str(FILLED["expected"])
	form._with_log.button_pressed = false
	form._submit()
	assert_signal_emitted_with_parameters(form, "submitted", [FILLED, false])


func test_where_reports_are_not_relayed_the_form_says_so_and_sends_nothing() -> void:
	var form := BugReportDialog.new()
	add_child_autofree(form)
	watch_signals(form)
	form.open_with(null, "not relayed from here")
	assert_true(form._send.disabled, "nothing to send to")
	assert_eq(form._status.text, "not relayed from here")
	form._title.text = str(FILLED["title"])
	for key: String in form._fields:
		(form._fields[key] as TextEdit).text = str(FILLED[key])
	form._clear_error()
	assert_eq(form._status.text, "not relayed from here", "typing does not wipe the reason")
	form._submit()
	assert_signal_not_emitted(form, "submitted")


func test_the_capture_travels_as_a_jpeg_no_wider_than_full_hd() -> void:
	var shot := Image.create(3840, 2160, false, Image.FORMAT_RGB8)
	shot.fill(Color(0.2, 0.4, 0.6))
	var bytes: PackedByteArray = Marshalls.base64_to_raw(BugReporter.encode_capture(shot))
	assert_eq(Array(bytes.slice(0, 3)), [0xff, 0xd8, 0xff], "a JPEG, which the service checks")
	var sent := Image.new()
	assert_eq(sent.load_jpg_from_buffer(bytes), OK)
	assert_eq(sent.get_size(), Vector2i(1920, 1080), "scaled down, its shape kept")
	assert_eq(shot.get_size(), Vector2i(3840, 2160), "the capture itself is left as it is")
	assert_eq(BugReporter.encode_capture(null), "", "no capture, nothing sent for it")
	assert_null(BugReporter.preview_of(null))
	assert_eq(BugReporter.preview_of(shot).get_width(), BugReporter.PREVIEW_WIDTH, "the form shows a small one")


func test_the_report_says_the_build_and_where_the_body_stands() -> void:
	var frame := Node3D.new()
	frame.name = "Tarsis3"
	add_child_autofree(frame)
	var body := Node3D.new()
	frame.add_child(body)
	body.position = Vector3(12.34, -5.0, 7.06)
	var context: Dictionary = BugReporter.context_of(body)
	assert_eq(context.get("version"), BuildInfo.version_text())
	assert_eq(context.get("frame"), "Tarsis3")
	assert_eq(context.get("position"), "12.3, -5.0, 7.1")
	for key: String in context:
		var value: Variant = context[key]
		assert_true(value is String or value is int or value is float or value is bool,
				"%s: a short text or a number, as the service takes it" % key)
		assert_lte(str(value).length(), 200, "%s fits the service's limit" % key)
	assert_true(BugReporter.context_of(null).has("version"), "with no body, the build and the machine still")


func test_no_token_leaves_with_the_log() -> void:
	var jwt := "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiI5YThiN2M2ZCJ9.c2lnbmF0dXJlLWJ5dGVz"
	var text := "args: --path . --token=%s --windowed\nAuthorization: Bearer %s\nloaded %s ok\nframe 12" % [jwt, jwt, jwt]
	var clean: String = BugReporter.scrub(text)
	assert_false(clean.contains("eyJ"), "the token is gone, however it was written")
	assert_true(clean.contains("--token=<token> --windowed"), "the argument's name stays, to read the line")
	assert_true(clean.contains("Bearer <token>"))
	assert_true(clean.contains("frame 12"), "the rest of the log is untouched")


func test_only_the_end_of_the_log_is_sent() -> void:
	var path := "user://test_bug_report_log.txt"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("START " + "x".repeat(5000) + " END")
	file.close()
	var tail: String = BugReporter.log_tail(path, 100)
	assert_eq(tail.length(), 100)
	assert_true(tail.ends_with(" END"), "its end")
	assert_false(tail.contains("START"))
	assert_eq(BugReporter.log_tail("user://no_such_log.txt"), "", "no log: the report goes without")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_the_version_is_the_project_s_then_the_build_s() -> void:
	var version := str(ProjectSettings.get_setting("application/config/version", ""))
	assert_true(BuildInfo.version_text().begins_with(version), "what the DataPad shows under the logo")
