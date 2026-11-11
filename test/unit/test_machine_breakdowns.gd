extends GutTest

## Breakdowns (services ADR 0020): what the server tells the simulator and takes back (MachineBreakdowns),
## what a client reads (BrokenMachines), a machine's id (MachineBreakdown) and the repair's small game
## (GaugePuzzle, MachineRepair).
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_machine_breakdowns.gd


func test_the_simulators_answer_gives_the_broken_machines() -> void:
	var broken := MachineBreakdowns.broken_of({"known": 3, "broken": [
		{"machineId": "m1", "breakdownId": "b1", "missionId": "x1"},
		{"machineId": "m2", "breakdownId": "b2", "missionId": null},
		{"machineId": "", "breakdownId": "b3"},
		"noise",
	]})
	assert_eq(broken, {"m1": {"breakdown": "b1", "mission": "x1"}, "m2": {"breakdown": "b2", "mission": ""}})
	assert_eq(MachineBreakdowns.broken_of(null), {})
	assert_eq(MachineBreakdowns.broken_of({"broken": 3}), {})


func test_a_planets_answer_replaces_what_was_known_of_its_machines_only() -> void:
	var known := {"here": {"breakdown": "b1", "mission": ""}, "elsewhere": {"breakdown": "b2", "mission": ""}}
	var answered := {"other": {"breakdown": "b3", "mission": "x"}}
	var merged := MachineBreakdowns.merged(known, ["here", "other"], answered, {})
	assert_false(merged.has("here"), "listed and not answered broken: it works")
	assert_true(merged.has("elsewhere"), "not listed: on another planet, or asleep")
	assert_true(merged.has("other"))


func test_a_machine_repaired_here_is_not_broken_again_by_an_older_answer() -> void:
	var answered := {"m1": {"breakdown": "b1", "mission": "x"}}
	assert_eq(MachineBreakdowns.merged({}, ["m1"], answered, {"b1": true}), {})


func test_the_repair_objective_is_the_one_naming_the_machine() -> void:
	var objectives := [
		{"id": "o1", "status": "pending", "payload": {"machineId": "other"}},
		{"id": "o2", "status": "pending", "payload": {"machineId": "m1"}},
	]
	assert_eq(MachineBreakdowns.repair_objective(objectives, "m1"), "o2")
	assert_eq(MachineBreakdowns.repair_objective(objectives, "nobody"), "")
	objectives[1]["status"] = "completed"
	assert_eq(MachineBreakdowns.repair_objective(objectives, "m1"), "", "already repaired")
	assert_eq(MachineBreakdowns.repair_objective(null, "m1"), "")
	assert_true(MachineRepair.names_machine([{"status": "pending", "payload": {"machineId": "m1"}}], "m1"))
	assert_false(MachineRepair.names_machine([{"status": "completed", "payload": {"machineId": "m1"}}], "m1"))
	assert_false(MachineRepair.names_machine([{"status": "pending"}], "m1"))


func test_what_a_client_reads_as_broken() -> void:
	assert_eq(BrokenMachines.ids_of({"items": [{"machineId": "m1", "kind": "crusher"}, {"kind": "lift"}, 4]}), {"m1": true})
	assert_eq(BrokenMachines.ids_of(null), {})


func test_a_repaired_machine_restarts_before_it_works_again() -> void:
	BrokenMachines._ids = {"m1": true}
	BrokenMachines._restarting = {}
	BrokenMachines.mark_repaired("m1", null, 1000)
	assert_false(BrokenMachines.is_broken("m1"), "repaired")
	assert_almost_eq(BrokenMachines.restart_left("m1", 1000), MachineBreakdown.RESTART_S, 0.001)
	assert_almost_eq(BrokenMachines.restart_left("m1", 1000 + 29500), 0.5, 0.001)
	assert_eq(BrokenMachines.restart_left("m1", 1000 + 31000), 0.0, "it works again")
	assert_eq(BrokenMachines.restart_left("other", 1000), 0.0)
	assert_eq(MachineBreakdown.seconds_shown(29.2), 30)
	assert_eq(MachineBreakdown.seconds_shown(0.4), 1, "never 0 while something is left")
	assert_eq(MachineBreakdown.seconds_shown(0.0), 0)
	BrokenMachines._ids = {}
	BrokenMachines._restarting = {}


func test_a_restarting_machine_scrolls_its_code() -> void:
	assert_eq(BootLog.lines_at(0.0), 0)
	assert_eq(BootLog.lines_at(BootLog.LINE_S * 5.5), 5)
	assert_eq(BootLog.text(0), "", "nothing yet")
	assert_eq(BootLog.text(3).split("\n").size(), 3, "it fills up")
	var full := BootLog.text(400).split("\n")
	assert_eq(full.size(), BootLog.ROWS, "then the last rows only")
	assert_ne(BootLog.text(400), BootLog.text(401), "a line further")
	var source := BootLog.SOURCE.split("\n")
	assert_eq(full[full.size() - 1], source[399 % source.size()], "the code starts over when it ends")
	assert_true(BootLog.lines_at(MachineBreakdown.RESTART_S) > source.size(), "it scrolls the whole restart long")


func test_the_server_keeps_a_restarting_machine_out_of_use() -> void:
	MachineBreakdowns._restarting = {"m1": 5000}
	assert_true(MachineBreakdowns.is_restarting("m1", 4999))
	assert_false(MachineBreakdowns.is_restarting("m1", 5000), "the restart is over")
	assert_false(MachineBreakdowns._restarting.has("m1"), "and forgotten")
	assert_false(MachineBreakdowns.is_restarting("other", 0))


func test_a_wall_screen_reads_the_crosshair_on_its_face() -> void:
	var size := Vector2(2.0, 1.0)
	assert_eq(WallScreen.uv_of(Vector3.ZERO, size), Vector2(0.5, 0.5), "the middle")
	assert_eq(WallScreen.uv_of(Vector3(-1.0, 0.5, 0.0), size), Vector2(0.0, 0.0), "the top-left corner")
	assert_eq(WallScreen.uv_of(Vector3(1.0, -0.5, 0.0), size), Vector2(1.0, 1.0))
	assert_true(WallScreen.uv_of(Vector3(1.2, 0.0, 0.0), size).x > 1.0, "off the face")


func test_a_machine_is_its_object_or_a_part_of_it() -> void:
	assert_eq(MachineBreakdown.id_of("abc", "."), "abc", "the networked object itself")
	var landing := MachineBreakdown.id_of("abc", "Landings/Top")
	assert_ne(landing, "abc")
	assert_eq(landing, MachineBreakdown.id_of("abc", "Landings/Top"), "the same on the server and on every client")
	assert_ne(landing, MachineBreakdown.id_of("abc", "Landings/Bottom"))
	assert_eq(MachineBreakdown.id_of("", "Landings/Top"), "", "inside nothing networked")


func test_a_gauge_reads_its_regulator_and_some_of_the_next() -> void:
	var read := GaugePuzzle.values([1.0, 0.0, 0.0])
	assert_almost_eq(float(read[0]), 1.0 / (1.0 + GaugePuzzle.COUPLING), 1.0e-6)
	assert_almost_eq(float(read[1]), 0.0, 1.0e-6)
	assert_almost_eq(float(read[2]), GaugePuzzle.COUPLING / (1.0 + GaugePuzzle.COUPLING), 1.0e-6, "the last takes the first's")
	assert_eq(GaugePuzzle.values([2.0, -1.0, 0.5])[0], 1.0 / (1.0 + GaugePuzzle.COUPLING), "regulators stop at their ends")


func test_a_puzzle_starts_out_of_line_and_can_be_solved() -> void:
	for puzzle_seed: int in 200:
		var puzzle := GaugePuzzle.make(puzzle_seed)
		var targets: Array = puzzle["targets"]
		assert_false(GaugePuzzle.aligned(GaugePuzzle.values(puzzle["start"]), targets), "seed %d starts solved" % puzzle_seed)
		# The regulators that give the targets, found gauge by gauge: read = (own + c * next) / (1 + c).
		var c := GaugePuzzle.COUPLING
		var t0: float = float(targets[0]) * (1.0 + c)
		var t1: float = float(targets[1]) * (1.0 + c)
		var t2: float = float(targets[2]) * (1.0 + c)
		var s0: float = (t0 - c * t1 + c * c * t2) / (1.0 + c * c * c)
		var s1: float = t1 - c * (t2 - c * s0)
		var s2: float = t2 - c * s0
		for s: float in [s0, s1, s2]:
			assert_between(s, 0.0, 1.0, "seed %d has no solution within the regulators' travel" % puzzle_seed)
		assert_true(GaugePuzzle.aligned(GaugePuzzle.values([s0, s1, s2]), targets))


func test_gauges_are_aligned_within_the_band_only() -> void:
	var targets := [0.2, 0.5, 0.8]
	assert_true(GaugePuzzle.aligned([0.2 + GaugePuzzle.TOLERANCE * 0.9, 0.5, 0.8], targets))
	assert_false(GaugePuzzle.aligned([0.2 + GaugePuzzle.TOLERANCE * 1.1, 0.5, 0.8], targets))
	assert_false(GaugePuzzle.aligned([0.2, 0.5], targets))
