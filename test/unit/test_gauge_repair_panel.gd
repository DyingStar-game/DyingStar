extends GutTest

## The repair's panel (GaugeRepairPanel): the diagnosis, then the gauges for who holds the mission, the way
## out for who does not; and its controller (MachineRepair).
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_gauge_repair_panel.gd


func _dialog() -> GaugeRepairPanel:
	var dialog := GaugeRepairPanel.new()
	add_child_autofree(dialog)
	return dialog


func test_it_opens_on_the_diagnosis_and_waits_for_the_mission_to_be_looked_for() -> void:
	var dialog := _dialog()
	assert_false(dialog.visible)
	dialog.open()
	assert_true(dialog.visible)
	dialog._process(GaugeRepairPanel.DIAGNOSIS_S + 0.1)
	assert_eq(dialog._phase, GaugeRepairPanel.Phase.DIAGNOSING, "the mission is not looked for yet")
	dialog.set_may_repair(false, 1)
	dialog._process(0.1)
	assert_eq(dialog._phase, GaugeRepairPanel.Phase.FAULT, "told to take the mission")
	assert_false(dialog._rows.visible)


func test_who_holds_the_mission_aligns_the_gauges() -> void:
	var dialog := _dialog()
	watch_signals(dialog)
	dialog.open()
	dialog.set_may_repair(true, 7)
	dialog._process(GaugeRepairPanel.DIAGNOSIS_S + 0.1)
	assert_eq(dialog._phase, GaugeRepairPanel.Phase.GAUGES)
	assert_true(dialog._rows.visible)
	dialog._process(GaugeRepairPanel.HOLD_S + 0.1)
	assert_signal_not_emitted(dialog, "aligned", "it starts out of line")
	# The regulators that give the targets (see test_machine_breakdowns for the algebra).
	var c := GaugePuzzle.COUPLING
	var t: Array = dialog._targets.map(func(v: float) -> float: return v * (1.0 + c))
	var s0: float = (t[0] - c * t[1] + c * c * t[2]) / (1.0 + c * c * c)
	var s2: float = t[2] - c * s0
	var s1: float = t[1] - c * s2
	for i: int in 3:
		dialog._sliders[i].value = [s0, s1, s2][i]
	dialog._process(GaugePuzzle.TOLERANCE)  # in the band, not long enough
	assert_signal_not_emitted(dialog, "aligned")
	dialog._process(GaugeRepairPanel.HOLD_S)
	assert_signal_emitted(dialog, "aligned")
	dialog.show_sent()
	assert_false(dialog._sliders[0].editable)
	dialog.close()
	assert_false(dialog.visible)


func test_it_is_laid_out_for_the_screens_shape_and_fills_it() -> void:
	var least := GaugeRepairPanel.DESIGN_PX
	assert_eq(GaugeRepairPanel.design_for(least * 2.0), least, "the same shape: the least size, scaled")
	var wide := GaugeRepairPanel.design_for(Vector2(least.y * 3.0, least.y))
	assert_eq(wide, Vector2(least.y * 3.0, least.y), "a wide screen: wider, as high")
	var tall := GaugeRepairPanel.design_for(Vector2(least.x * 0.5, least.x))
	assert_eq(tall, Vector2(least.x, least.x * 2.0), "a tall screen: as wide, higher")
	assert_eq(GaugeRepairPanel.design_for(Vector2.ZERO), least)
	var dialog := _dialog()
	dialog.fit(Vector2(3840.0, 1200.0))
	assert_almost_eq(dialog.size.x * dialog.scale.x, 3840.0, 0.01)
	assert_almost_eq(dialog.size.y * dialog.scale.y, 1200.0, 0.01)


func test_the_players_around_watch_the_repair() -> void:
	var mine := _dialog()
	mine.open()
	mine.set_may_repair(true, 7)
	mine._process(GaugeRepairPanel.DIAGNOSIS_S + 0.1)
	mine._sliders[0].value = 0.25
	# Through the network (JSON): the ints come back floats.
	var view: Dictionary = JSON.parse_string(JSON.stringify(mine.view_state()))
	var theirs := _dialog()
	watch_signals(theirs)
	theirs.apply_view_state(view)
	assert_true(theirs.visible)
	assert_true(theirs.watched)
	assert_true(theirs._rows.visible)
	assert_almost_eq(theirs._sliders[0].value, 0.25, 0.001)
	assert_almost_eq(theirs._gauges[1].target, float(mine._targets[1]), 0.001)
	assert_false(theirs._sliders[0].editable, "nothing answers the one watching")
	theirs._process(GaugeRepairPanel.HOLD_S * 4.0)
	assert_signal_not_emitted(theirs, "aligned", "the repair is not theirs to send")
	mine.close()
	theirs.apply_view_state(JSON.parse_string(JSON.stringify(mine.view_state())))
	assert_false(theirs.visible, "closed there, closed here")


## A machine's screen as MachineBreakdown finds it: a wall screen's contract, drawn in its own viewport.
class FakeScreen:
	extends Node3D
	var viewport := SubViewport.new()
	var interactive := false

	func _init() -> void:
		viewport.size = Vector2i(1200, 600)
		add_child(viewport)

	func update_screen(_data: Dictionary) -> void:
		pass

	func breakdown_viewport() -> SubViewport:
		return viewport

	func breakdown_prompt_size() -> Vector2:
		return Vector2(2.0, 1.0)

	func set_interactive(on: bool) -> void:
		interactive = on


func _broken_screen() -> MachineBreakdown:
	var host := FakeScreen.new()
	add_child_autofree(host)
	var breakdown := MachineBreakdown.attach(host, "screen")
	breakdown._id = "machine-under-test"
	BrokenMachines._ids = {"machine-under-test": true}
	BrokenMachines._restarting = {}
	breakdown.refresh()
	return breakdown


func after_each() -> void:
	BrokenMachines._ids = {}
	BrokenMachines._restarting = {}


func test_the_repair_opens_on_the_machines_own_screen() -> void:
	var repair := MachineRepair.new()
	add_child_autofree(repair)
	repair.setup(func(_text: String) -> void: pass)
	assert_false(repair.is_open())
	var breakdown := _broken_screen()
	var host: FakeScreen = breakdown.host()
	MachineRepair.open_for(breakdown)
	assert_true(repair.is_open(), "the diagnosis is on screen at once, whatever the services answer")
	var panel := breakdown.repair_panel()
	assert_eq(panel.get_viewport(), host.viewport, "in the screen, not over the game")
	assert_almost_eq(panel.size.x * panel.scale.x, 1200.0, 0.01, "it fills the screen")
	assert_true(host.interactive, "a screen that takes no click takes the crosshair meanwhile")
	assert_false(breakdown._words.visible)
	panel.dismiss()
	assert_false(repair.is_open())
	assert_false(host.interactive)
	assert_true(breakdown._words.visible, "the breakdown's words are back")


func test_the_controller_survives_the_player_changing_frame() -> void:
	# The player is moved under a planet, a vehicle: out of the tree and in again.
	var holder := Node.new()
	add_child_autofree(holder)
	var repair := MachineRepair.new()
	holder.add_child(repair)
	repair.setup(func(_text: String) -> void: pass)
	holder.remove_child(repair)
	holder.add_child(repair)
	MachineRepair.open_for(_broken_screen())
	assert_true(repair.is_open())


func test_a_repaired_machine_counts_its_restart_down_then_works() -> void:
	var breakdown := _broken_screen()
	assert_eq(breakdown._shown, MachineBreakdown.Shown.BROKEN)
	assert_not_null(breakdown._prompt, "repaired from its prompt")
	breakdown.repair_panel().open()
	BrokenMachines.mark_repaired("machine-under-test", get_tree())
	assert_eq(breakdown._shown, MachineBreakdown.Shown.RESTARTING)
	assert_true(breakdown.is_broken(), "still out of use")
	assert_true(breakdown._cover.visible)
	assert_false(breakdown.repair_panel().visible, "the repair is over")
	assert_eq(breakdown._counted, int(MachineBreakdown.RESTART_S))
	assert_null(breakdown._prompt, "nothing to diagnose")
	BrokenMachines._restarting = {}
	breakdown._process(MachineBreakdown.COUNTDOWN_CHECK_S)
	assert_eq(breakdown._shown, MachineBreakdown.Shown.WORKING)
	assert_false(breakdown._cover.visible)
	assert_false(breakdown.is_broken())


func test_it_never_asks_for_more_room_than_its_design_size() -> void:
	# On a dispenser's square screen the panel was wider than the screen: "Close" ran off its right edge.
	for locale: String in ["en", "fr"]:
		TranslationServer.set_locale(locale)
		var dialog := _dialog()
		dialog.fit(Vector2(1024.0, 1024.0))
		dialog.open()
		dialog.set_may_repair(false, 1)
		dialog._process(GaugeRepairPanel.DIAGNOSIS_S + 0.1)
		await wait_process_frames(2)
		assert_lte(dialog.get_combined_minimum_size().x, dialog.size.x, "%s, no mission: as wide as laid out" % locale)
		assert_almost_eq(dialog.size.x * dialog.scale.x, 1024.0, 0.01, "%s: it ends at the screen's edge" % locale)
		dialog.open()
		dialog.set_may_repair(true, 1)
		dialog._process(GaugeRepairPanel.DIAGNOSIS_S + 0.1)
		await wait_process_frames(2)
		assert_lte(dialog.get_combined_minimum_size().y, GaugeRepairPanel.DESIGN_PX.y, "%s, gauges: no taller than the least screen" % locale)
		assert_almost_eq(dialog.size.x * dialog.scale.x, 1024.0, 0.01)
	TranslationServer.set_locale("en")
