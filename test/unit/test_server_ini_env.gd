extends GutTest
## A server.ini `[debug]` switch is overridden by DS_<KEY> when that variable is set, either way, so a
## Kubernetes pod is switched by its env without a new image.

const VAR := "DS_PERF_CENSUS"


func after_each() -> void:
	OS.unset_environment(VAR)


func test_the_env_values_read_as_switches() -> void:
	for on: String in ["1", "true", "TRUE", " yes ", "on"]:
		assert_eq(SettingsManager.env_flag(on), 1, on)
	for off: String in ["0", "false", "no", "off"]:
		assert_eq(SettingsManager.env_flag(off), 0, off)
	for unset: String in ["", "maybe"]:
		assert_eq(SettingsManager.env_flag(unset), -1, "'%s' leaves it to the ini" % unset)


func test_the_env_wins_over_the_ini_both_ways() -> void:
	OS.set_environment(VAR, "1")
	assert_true(SettingsManager._server_ini_flag("debug", "perf_census"), "on by the pod")
	OS.set_environment(VAR, "0")
	assert_false(SettingsManager._server_ini_flag("debug", "perf_census"), "off by the pod")


func test_only_debug_keys_are_overridden() -> void:
	OS.set_environment("DS_ENABLED", "1")
	assert_false(SettingsManager._server_ini_flag("metrics", "enabled"), "[metrics] stays the ini's")
	OS.unset_environment("DS_ENABLED")
