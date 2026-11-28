extends GutTest
## The squad panel and a squad the player forgot they were in (playtest of 2026-11-26: "already in a
## squad... or not"): creating one was refused, and "My squad" showed none -- it had never been loaded.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##         -gtest=res://test/unit/test_groups_panel.gd -gexit

const GROUPS_PANEL := preload("res://ui/services/groups_panel.gd")


func test_a_creation_refused_for_a_squad_already_held_is_told_apart() -> void:
	assert_true(GROUPS_PANEL.already_in_group({"ok": false, "status": 409, "error": "ALREADY_IN_GROUP"}))
	assert_false(GROUPS_PANEL.already_in_group({"ok": false, "status": 409, "error": "GROUP_NAME_TAKEN"}),
			"another refusal is reported as it is")
	assert_false(GROUPS_PANEL.already_in_group({"ok": true, "error": ""}))


func test_a_squad_that_could_not_be_read_offers_to_ask_again_not_to_create_one() -> void:
	var panel: ServicePanel = GROUPS_PANEL.new()
	add_child_autofree(panel)
	panel._apply_group({"ok": false, "status": 0, "error": "UNREACHABLE"})
	var labels: Array[String] = _button_texts(panel._none_card)
	assert_has(labels, tr("%%SVC_ACT_REFRESH"), "the way out of a failed read is to read again")
	assert_does_not_have(labels, tr("%%SVC_SQ_CREATE_ONE"), "nothing says the player has no squad")
	panel._apply_group({"ok": true, "data": null})
	assert_has(_button_texts(panel._none_card), tr("%%SVC_SQ_CREATE_ONE"), "no squad: one can be created")


func _button_texts(under: Node) -> Array[String]:
	var texts: Array[String] = []
	for node: Node in under.find_children("*", "Button", true, false):
		texts.append((node as Button).text)
	return texts
