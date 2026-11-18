extends GutTest
## The in-game bug report (F9): what the form accepts, what the report carries, and what never leaves
## the machine. The sending itself is service-social's (its own tests): here, a report is built.


func test_the_key_is_an_action_filed_with_the_captures() -> void:
	InputMap.load_from_project_settings()
	assert_true(InputMap.has_action(&"bug_report"), "a key of the InputMap, rebindable")
	var gallery: Dictionary = MenuConfig.ACTION_GROUPS["%%KM_GROUP_GENERAL"]["%%KM_SECTION_GALLERY"]
	assert_eq(gallery.get("bug_report"), "%%ACT_BUG_REPORT", "listed in Settings > Controls, with F7 and F8")


func test_the_form_wants_a_title_and_a_description() -> void:
	assert_eq(BugReportDialog.error_key("ab", "it broke"), "%%BUG_REPORT_TITLE_SHORT")
	assert_eq(BugReportDialog.error_key("  a  ", "it broke"), "%%BUG_REPORT_TITLE_SHORT", "spaces do not count")
	assert_eq(BugReportDialog.error_key("Stuck in the truck", "   "), "%%BUG_REPORT_DESCRIPTION_EMPTY")
	assert_eq(BugReportDialog.error_key("Stuck in the truck", "x".repeat(BugReportDialog.DESCRIPTION_MAX + 1)),
			"%%BUG_REPORT_DESCRIPTION_LONG")
	assert_eq(BugReportDialog.error_key("Stuck in the truck", "Teleported from the seat."), "", "good to send")


func test_the_form_sends_cleaned_texts_and_says_what_is_wrong() -> void:
	var form := BugReportDialog.new()
	add_child_autofree(form)
	watch_signals(form)
	form.open_with(null)
	assert_true(form.is_open())
	form._title.text = "a"
	form._description.text = "it broke"
	form._submit()
	assert_signal_not_emitted(form, "submitted", "a title too short is not sent")
	assert_ne(form._status.text, "", "and the form says why")
	form._title.text = "  Stuck in the truck "
	form._description.text = "Teleported from the seat.\n"
	form._with_log.button_pressed = false
	form._submit()
	assert_signal_emitted_with_parameters(form, "submitted", ["Stuck in the truck", "Teleported from the seat.", false])


func test_where_reports_are_not_relayed_the_form_says_so_and_sends_nothing() -> void:
	var form := BugReportDialog.new()
	add_child_autofree(form)
	watch_signals(form)
	form.open_with(null, "not relayed from here")
	assert_true(form._send.disabled, "nothing to send to")
	assert_eq(form._status.text, "not relayed from here")
	form._title.text = "Stuck in the truck"
	form._description.text = "Teleported from the seat."
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
