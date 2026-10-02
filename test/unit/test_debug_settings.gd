extends GutTest
## DebugSettings: the Settings > Debug switches, on a ConfigFile of the test's own (nothing reaches
## settings.ini). A write is saved and announced; a preview is announced only; a listener whose
## object is gone is dropped instead of being called.

var _config : ConfigFile
var _saves : int = 0
var _debug : DebugSettings


class Listener extends Object:
	var got : Array = []

	func on_change(on: bool) -> void:
		got.append(on)


func before_each() -> void:
	_config = ConfigFile.new()
	_saves = 0
	_debug = DebugSettings.new(_config, func() -> void: _saves += 1, func(_s: String, _k: String) -> bool: return false)


func test_every_switch_starts_at_its_default() -> void:
	for key: StringName in DebugSettings.DEFAULTS:
		assert_eq(_debug.is_on(key), DebugSettings.DEFAULTS[key], str(key))


func test_write_defaults_puts_them_in_the_file() -> void:
	_debug.write_defaults()
	assert_eq(_config.get_value(DebugSettings.SECTION, "show_debug"), true)
	assert_eq(_config.get_value(DebugSettings.SECTION, "star_map_debug"), false)


func test_a_write_is_stored_saved_and_announced() -> void:
	watch_signals(_debug)
	_debug.set_on(&"star_map_debug", true)
	assert_true(_debug.is_on(&"star_map_debug"))
	assert_eq(_saves, 1, "saved once")
	assert_signal_emitted_with_parameters(_debug, "changed", [&"star_map_debug", true])


func test_a_preview_is_announced_but_not_stored() -> void:
	watch_signals(_debug)
	_debug.preview(&"show_debug", false)
	assert_true(_debug.is_on(&"show_debug"), "the stored value is untouched")
	assert_eq(_saves, 0, "nothing saved")
	assert_signal_emitted_with_parameters(_debug, "changed", [&"show_debug", false])


func test_a_watcher_hears_its_switch_only() -> void:
	var listener := Listener.new()
	_debug.watch(&"cargo_debug", listener.on_change)
	_debug.set_on(&"music_debug", true)
	_debug.set_on(&"cargo_debug", true)
	assert_eq(listener.got, [true], "the cargo switch, not the music one")
	listener.free()


func test_a_freed_watcher_is_dropped() -> void:
	var listener := Listener.new()
	_debug.watch(&"cargo_debug", listener.on_change)
	listener.free()
	_debug.set_on(&"cargo_debug", true)  # would error on a freed object
	assert_eq((_debug._watchers[&"cargo_debug"] as Array).size(), 0, "forgotten")
