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
	"severity": "minor",
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


## How bad it is: chosen in a list, worst first, and sent as the key the service knows.
func test_the_report_says_how_bad_the_bug_is() -> void:
	var keys: Array = BugReportDialog.SEVERITIES.map(func(severity: Dictionary) -> String: return severity["key"])
	assert_eq(keys, ["blocker", "major", "minor", "cosmetic"], "service-social's BUG_SEVERITIES, worst first")
	var form := BugReportDialog.new()
	add_child_autofree(form)
	form.open_with([])
	assert_eq(form.report().get("severity"), BugReportDialog.DEFAULT_SEVERITY, "a form opens on the default")
	form._severity.select(BugReportDialog.severity_index("blocker"))
	assert_eq(form.report().get("severity"), "blocker")
	form.open_with([])
	assert_eq(form.report().get("severity"), BugReportDialog.DEFAULT_SEVERITY, "the next report starts over")
	assert_eq(BugReportDialog.severity_index("unheard of"), -1)


## Tab walks the form in the template's order. A text area would type the tab instead: told not to.
func test_tab_goes_from_one_field_to_the_next() -> void:
	var form := BugReportDialog.new()
	add_child_autofree(form)
	form.open_with([])
	var order: Array[Control] = [form._title, form._severity]
	for part: Dictionary in BugReportDialog.PARTS:
		var field: TextEdit = form._fields[part["key"]]
		assert_false(field.tab_input_mode, "%s: Tab is not typed" % part["key"])
		order.append(field)
	order.append(form._with_log)
	for i: int in order.size() - 1:
		assert_eq(order[i].find_next_valid_focus(), order[i + 1], "Tab from field %d" % i)
		assert_eq(order[i + 1].find_prev_valid_focus(), order[i], "Shift + Tab back to field %d" % i)


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
	form.open_with([])
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
	form.open_with([], "not relayed from here")
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


func test_the_report_says_the_build_and_where_the_player_stood() -> void:
	var place := {"world": "12.3, -5.0, 7.1", "planet": "Tarsis3, 12.00000° N, 3.00000° E, alt 40 m", "frame": "Tarsis3",
			"else": "not a place"}
	var context: Dictionary = BugReporter.context_of(place)
	assert_eq(context.get("version"), BuildInfo.version_text())
	for key: String in BugReporter.PLACE_KEYS:
		assert_eq(context.get(key), place[key], "%s, as the player's role gave it" % key)
	assert_false(context.has("else"), "only what a place is made of")
	for key: String in context:
		var value: Variant = context[key]
		assert_true(value is String or value is int or value is float or value is bool,
				"%s: a short text or a number, as the service takes it" % key)
		assert_lte(str(value).length(), 200, "%s fits the service's limit" % key)
	var nowhere: Dictionary = BugReporter.context_of({})
	assert_true(nowhere.has("version"), "in a menu, the build and the machine still")
	assert_false(nowhere.has("world"), "and no place made up")
	assert_lte(context.size(), 20, "the service keeps 20 entries of the context")


## World and planet coordinates, as the debug panel reads them: the place a bug is looked for at.
func test_the_place_is_the_world_s_and_the_planet_s() -> void:
	var frame := Node3D.new()
	frame.name = "Hangar"
	add_child_autofree(frame)
	frame.global_position = Vector3(1000.0, 0.0, 0.0)
	var body := Node3D.new()
	frame.add_child(body)
	body.position = Vector3(12.34, -5.0, 7.06)
	var place: Dictionary = DevReadouts.coordinates(body)
	assert_eq(place.get("world"), "1012.3, -5.0, 7.1", "where it is in the system, not in its parent")
	assert_eq(place.get("frame"), "Hangar")
	assert_false(place.has("planet"), "on no planet: nothing said of one")
	assert_eq(DevReadouts.coordinates(null), {}, "no body, no place")
	var gone := Node3D.new()
	gone.free()
	assert_eq(DevReadouts.coordinates(gone), {}, "a body freed meanwhile is no error")


## What QA asks first: on what machine. One short line a subject, and nothing that names its owner.
func test_the_report_describes_the_machine() -> void:
	var machine: Dictionary = BugReporter.machine_of()
	for key: String in ["os", "cpu", "ram", "gpu", "gpu_driver", "vram", "renderer", "display", "engine"]:
		assert_true(machine.has(key), "%s is told" % key)
		assert_true(machine.get(key) is String, "%s: a text" % key)
		assert_lte(str(machine.get(key, "")).length(), BugReporter.CONTEXT_VALUE_MAX, "%s fits the service's limit" % key)
	var user: String = OS.get_environment("USERNAME") + OS.get_environment("USER")
	if user.length() >= 3:
		assert_false(str(machine).contains(user), "the account's name is nowhere in it")
	assert_eq(BugReporter.size_text(34252779520), "31.9 GB")
	assert_eq(BugReporter.size_text(536870912), "512 MB")
	assert_eq(BugReporter.size_text(-1), "unknown", "what the system could not read")
	# "available" counts the page file: on a 32 GB machine it read 61 GB free (playtest 2026-11-18).
	var memory := {"physical": 33500000000, "free": 7300000000, "available": 65700000000}
	assert_eq(BugReporter.ram_text(memory, 1717986918), "31.2 GB, 6.8 GB free, 1.6 GB used by the game",
			"the memory free in the machine, never more than it has")


## An export carries its build id. Run from the sources there is none: the branch and the commit say
## which game it was.
func test_a_game_run_from_its_sources_says_which() -> void:
	var dir := OS.get_user_data_dir().path_join("test_bug_report_git")
	DirAccess.make_dir_recursive_absolute(dir.path_join(".git/refs/heads/feat"))
	assert_eq(BugReporter.build_of(dir), "sources", "no git there")
	_write(dir.path_join(".git/HEAD"), "ref: refs/heads/feat/horn\n")
	assert_eq(BugReporter.build_of(dir), "sources feat/horn", "the commit is packed away: the branch alone")
	_write(dir.path_join(".git/refs/heads/feat/horn"), "1a2b3c4d5e6f7890\n")
	assert_eq(BugReporter.build_of(dir), "sources feat/horn@1a2b3c4")
	_write(dir.path_join(".git/HEAD"), "9f8e7d6c5b4a3210\n")
	assert_eq(BugReporter.build_of(dir), "sources @9f8e7d6", "a commit checked out by itself")
	OS.move_to_trash(dir)
	assert_ne(BugReporter.build_of(), "", "the running game always says something")


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


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


## A bug shows in a menu as well as in the world: the key is the capture keys' autoload's, not the
## player's, and nothing locks it.
func test_the_key_answers_without_a_player() -> void:
	assert_not_null(Screenshot.bug_reporter, "made with the capture keys, before any world")
	assert_false(Screenshot.bug_reporter.is_open())
	assert_true(BugReporter.context_of({}).has("build"), "no place: the build and the machine are still told")


## Over a menu, the form has the keys: the menus stand back (MenuFocus.modal) until it closes, and
## Tab is the form's own -- the chat and the chart each have a use for it otherwise.
func test_the_form_keeps_the_keys_from_what_is_under_it() -> void:
	var form := BugReportDialog.new()
	add_child_autofree(form)
	MenuFocus.modal = false
	form.open_with([])
	assert_true(MenuFocus.modal, "open: the menus leave the focus alone")
	assert_eq(form.get_index(), form.get_parent().get_child_count() - 1, "and the form is asked first about a key")
	form._title.grab_focus()
	form.walk_focus(false)
	assert_eq(get_viewport().gui_get_focus_owner(), form._severity, "Tab: on to the severity")
	form.walk_focus(false)
	assert_eq(get_viewport().gui_get_focus_owner(), form._fields["description"], "then the description")
	form.walk_focus(true)
	assert_eq(get_viewport().gui_get_focus_owner(), form._severity, "Shift + Tab: back")
	form.close()
	assert_false(MenuFocus.modal, "closed: the menus have their keys back")
	form.close()
	assert_false(MenuFocus.modal, "closing twice changes nothing")


## The key is recalled in a corner of the screen, everywhere: written as the prompts write a key, with
## the key bound now, and on a layer of its own so the F7 photo hides it with the rest.
func test_the_key_is_recalled_in_the_corner_of_the_screen() -> void:
	assert_eq(BugReporter.hint_text("F9", "Report a bug"), "[F9] Report a bug")
	assert_eq(BugReporter.hint_text("", "Report a bug"), "", "no key bound: nothing to press, nothing said")
	var reporter := BugReporter.new()
	add_child_autofree(reporter)
	reporter._refresh_hint()
	assert_not_null(reporter._hint, "made at the first look")
	assert_true(reporter._hint.get_parent() is CanvasLayer, "interface: hidden from a photo")
	assert_eq(reporter._hint.mouse_filter, Control.MOUSE_FILTER_IGNORE, "it never takes a click")
	assert_true(reporter._hint.text.begins_with("[%s]" % InputLabel.for_action(&"bug_report")), "the key as it is bound")
	assert_true(reporter._hint.visible)


## A report carries up to five captures: each shows in the form, a click takes one off, and the
## button that asks for one more goes off when the report is full.
func test_the_form_shows_the_captures_and_lets_one_go() -> void:
	var form := BugReportDialog.new()
	add_child_autofree(form)
	watch_signals(form)
	var picture: Texture2D = BugReportDialog.mark_of(Color.RED)
	form.open_with([picture, picture])
	assert_eq(form._thumbs.get_child_count(), 2)
	assert_false(form._add_capture.disabled, "room for more")
	(form._thumbs.get_child(1) as TextureButton).pressed.emit()
	assert_signal_emitted_with_parameters(form, "capture_removed", [1])
	var full: Array = []
	full.resize(BugReportDialog.MAX_CAPTURES)
	full.fill(picture)
	form.show_captures(full)
	assert_true(form._add_capture.disabled, "five captures: the report is full")


## "Continue later" and "attach another capture" close the form on what was typed; opened again on
## the same report, it is all there. A new report starts on empty fields.
func test_a_report_put_aside_comes_back_as_it_was_typed() -> void:
	var form := BugReportDialog.new()
	add_child_autofree(form)
	watch_signals(form)
	MenuFocus.modal = false
	form.open_with([])
	form._title.text = "Stuck in the truck"
	(form._fields["steps"] as TextEdit).text = "1. Sit at the wheel"
	form._severity.select(BugReportDialog.severity_index("major"))
	form._later.pressed.emit()
	assert_signal_emitted(form, "postponed")
	assert_false(form.is_open(), "out of the way")
	assert_false(MenuFocus.modal, "and the menus have their keys back")
	form.open_with([], "", "", {}, false)
	assert_eq(form._title.text, "Stuck in the truck")
	assert_eq((form._fields["steps"] as TextEdit).text, "1. Sit at the wheel")
	assert_eq(form.report().get("severity"), "major")
	form._add_capture.pressed.emit()
	assert_signal_emitted(form, "capture_asked")
	assert_false(form.is_open())
	form.open_with([])
	assert_eq(form._title.text, "", "a new report: nothing of the last one")
	assert_eq(form.report().get("severity"), BugReportDialog.DEFAULT_SEVERITY)


## Where the player stood is shown in the form: the world's line, and the planet's when on one.
func test_the_form_shows_where_the_player_stood() -> void:
	var form := BugReportDialog.new()
	add_child_autofree(form)
	form.open_with([], "", "", {"world": "1.0, 2.0, 3.0", "planet": "Tarsis3, 12.00000° N"})
	assert_true(form._world.visible)
	assert_true(form._world.text.contains("1.0, 2.0, 3.0"))
	assert_true(form._planet.text.contains("Tarsis3"))
	form.open_with([], "", "", {"world": "1.0, 2.0, 3.0"})
	assert_false(form._planet.visible, "in space: no planet line")
	form.open_with([])
	assert_false(form._world.visible, "in a menu: no place at all")


## The key, by where the report stands: postponed, it brings the form back and takes no capture; the
## reminder in the corner says what the key will do.
func test_the_key_brings_a_postponed_report_back() -> void:
	var reporter := BugReporter.new()
	add_child_autofree(reporter)
	reporter._captures.append({"jpeg": "abc", "small": null, "path": "user://shots/debug_1.png"})
	reporter._place = {"world": "1.0, 2.0, 3.0"}
	reporter._stage = BugReporter.Stage.POSTPONED
	reporter._refresh_hint()
	assert_true(reporter._hint.text.ends_with(tr("%%BUG_REPORT_RESUME")), "the corner says the key resumes")
	reporter.press()
	assert_eq(reporter._stage, BugReporter.Stage.FORM)
	assert_true(reporter.is_open(), "the form is back")
	assert_eq(reporter._captures.size(), 1, "and no capture was taken for it")
	reporter._dialog._add_capture.pressed.emit()
	assert_eq(reporter._stage, BugReporter.Stage.AWAITING_CAPTURE, "aside for one more capture")
	reporter._refresh_hint()
	assert_true(reporter._hint.text.ends_with(tr("%%BUG_REPORT_ADD_CAPTURE_HINT")))
	reporter._stage = BugReporter.Stage.FORM
	reporter._on_capture_removed(0)
	assert_true(reporter._captures.is_empty(), "a capture taken off in the form is off the report")
	reporter._dialog._dismiss()
	assert_eq(reporter._stage, BugReporter.Stage.IDLE, "cancelled: nothing is kept")
	assert_true(reporter._place.is_empty())
	reporter._dialog.queue_free()


## The first capture travels under the name every version of the service knows, the others beside it.
const KNOWN := [
	{"id": "1003", "title": "[PREPROD] Stuck in the truck", "status": "new"},
	{"id": "1001", "title": "[PREPROD] Truck horn silent", "status": "in_progress"},
	{"id": "1000", "title": "[PREPROD] Lamps on at noon", "status": "to_test"},
]


## A bug already posted is found by a few of its words, whatever their case and their order.
func test_an_open_bug_is_found_by_its_words() -> void:
	var ids := func(found: Array) -> Array: return found.map(func(bug: Dictionary) -> String: return bug["id"])
	assert_eq(ids.call(BugReportDialog.matching(KNOWN, "truck")), ["1003", "1001"], "in the list's order")
	assert_eq(ids.call(BugReportDialog.matching(KNOWN, "HORN truck")), ["1001"], "every word, any case, any order")
	assert_eq(BugReportDialog.matching(KNOWN, "  "), [], "nothing typed, nothing offered")
	assert_eq(BugReportDialog.matching(KNOWN, "volcano"), [])
	assert_eq(BugReportDialog.matching(KNOWN, "preprod", 2).size(), 2, "no more than asked")
	for status: String in ["new", "open", "in_progress", "to_test"]:
		assert_true(BugReportDialog.STATUSES.has(status), "%s: one of service-social's open statuses" % status)


## The form offers the open bugs; one picked, the report names its post. Typing again lets it go.
func test_a_report_can_be_added_to_a_bug_already_posted() -> void:
	var form := BugReportDialog.new()
	add_child_autofree(form)
	form.open_with([])
	assert_false(form._link_row.visible, "no list from the service: every report is a new bug")
	assert_false(form.report().has("thread_id"))
	form.set_known_bugs(KNOWN)
	assert_true(form._link_row.visible)
	assert_false(form._matches.visible, "nothing typed yet")
	form._link.text = "truck"
	form._on_link_typed("truck")
	assert_eq(form._matches.item_count, 2)
	form._pick_match(1)
	assert_eq(form.report().get("thread_id"), "1001", "the post the report is added to")
	assert_eq(form._link.text, "[PREPROD] Truck horn silent", "and the field says which")
	assert_false(form._matches.visible)
	form.set_known_bugs(KNOWN)
	assert_eq(form.report().get("thread_id"), "1001", "the list coming again does not undo the choice")
	form._on_link_typed("lamp")
	assert_false(form.report().has("thread_id"), "typing again: no longer that bug")
	form._pick_match(0)
	assert_eq(form.report().get("thread_id"), "1000")
	form.open_with([], "", "", {}, false)
	assert_eq(form.report().get("thread_id"), "1000", "a report put aside keeps it")
	form.open_with([])
	assert_false(form.report().has("thread_id"), "the next report starts over")
	assert_eq(form._link.text, "")


## What the service lists is taken as it comes, without what could not be picked.
func test_the_open_bugs_are_those_the_service_lists() -> void:
	var answer := {"ok": true, "data": {"enabled": true, "bugs": [KNOWN[0], {"id": "", "title": "x"}, "junk", KNOWN[1]]}}
	assert_eq(BugReporter.known_bugs_of(answer), [KNOWN[0], KNOWN[1]])
	assert_eq(BugReporter.known_bugs_of({"ok": false, "data": {"bugs": KNOWN}}), [], "the service did not answer")
	assert_eq(BugReporter.known_bugs_of({"ok": true, "data": {"enabled": false}}), [])
	var body: Dictionary = PlayerServices.bug_report_body({"title": "Stuck", "thread_id": "1001"}, {})
	assert_eq(body.get("thread_id"), "1001", "the post travels with the report")


func test_the_captures_travel_as_the_first_and_the_others() -> void:
	assert_true(BugReportDialog.MAX_CAPTURES <= 5, "service-social attaches five pictures at most")
	var body: Dictionary = PlayerServices.bug_report_body({"title": "Stuck"}, {"version": "1"}, ["one", "", "two", "three"], "log")
	assert_eq(body.get("screenshot"), "one", "the capture the bug shows on")
	assert_eq(body.get("extra_screenshots"), ["two", "three"], "the others, an empty one left out")
	assert_eq(body.get("title"), "Stuck")
	assert_eq(body.get("log"), "log")
	var bare: Dictionary = PlayerServices.bug_report_body({"title": "Stuck"}, {})
	assert_false(bare.has("screenshot") or bare.has("extra_screenshots") or bare.has("log"), "nothing sent for nothing")
