extends GutTest
## Voice stays off when a system library LiveKit loads by itself is missing: its loader stubs abort the
## whole game when it joins a room without them (NixOS through appimage-run, 2026-10-25).

const LIVEKIT_AUDIO := preload("res://scenes/audio/livekit.gd")


func test_the_probe_is_in_the_assembly() -> void:
	var script: Script = NativeScript.load_usable(LIVEKIT_AUDIO.NATIVE_LIBRARY_PROBE_SCRIPT, ["CanLoad"])
	assert_not_null(script, "NativeLibraryProbe.cs is built into the assembly")


func test_only_the_missing_libraries_are_named() -> void:
	var names: Array[String] = ["libc.so.6", "libno_such_library_dyingstar.so.1"]
	var missing: Array[String] = LIVEKIT_AUDIO.missing_system_libraries(names)
	if OS.get_name() == "Linux":
		assert_eq(missing, ["libno_such_library_dyingstar.so.1"] as Array[String], "libc loads, the other does not")
	else:
		assert_eq(missing, [] as Array[String], "nothing to check off Linux")


func test_the_va_api_libraries_are_checked() -> void:
	assert_has(LIVEKIT_AUDIO.SYSTEM_LIBRARIES, "libva.so.2")
	assert_has(LIVEKIT_AUDIO.SYSTEM_LIBRARIES, "libva-drm.so.2")
