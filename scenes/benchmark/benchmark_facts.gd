class_name BenchmarkFacts
extends RefCounted
## Everything the benchmark report says about the machine, the game and the place, read from the
## engine. Kept apart from BenchmarkReport so the formatting stays pure (and testable) while this
## reads the world.

const _MIB : float = 1048576.0
const _GIB : float = 1073741824.0
const _UPDATE_MODES : Dictionary = {
	SubViewport.UPDATE_DISABLED: "disabled", SubViewport.UPDATE_ONCE: "once",
	SubViewport.UPDATE_WHEN_VISIBLE: "when_visible", SubViewport.UPDATE_WHEN_PARENT_VISIBLE: "when_parent_visible",
	SubViewport.UPDATE_ALWAYS: "always",
}
const _ADAPTER_TYPES : Dictionary = {
	RenderingDevice.DEVICE_TYPE_OTHER: "other", RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU: "integrated",
	RenderingDevice.DEVICE_TYPE_DISCRETE_GPU: "discrete", RenderingDevice.DEVICE_TYPE_VIRTUAL_GPU: "virtual",
	RenderingDevice.DEVICE_TYPE_CPU: "cpu",
}


## The report's header: [[section, [[key, value], …]], …]. Read BEFORE the run changes anything, so
## the graphics line is the player's own settings. [param caps] the frame caps the run lifts:
## {max_fps, vsync}, as they were.
static func header(player: Node3D, caps: Dictionary) -> Array:
	var version : Dictionary = game_version()
	var memory : Dictionary = OS.get_memory_info()
	var window : Vector2i = DisplayServer.window_get_size()
	var root : Viewport = player.get_tree().root if is_instance_valid(player) else null
	var scale : float = root.scaling_3d_scale if root != null else 1.0
	var graphics : Array = [["preset", SettingsManager.render.preset()]]
	for option in GraphicsOptions.OPTIONS:
		graphics.append([option["key"], SettingsManager.render.effective(option["key"])])
	var overridden : PackedStringArray = SettingsManager.render.caps.get("overridden", PackedStringArray())
	graphics.append(["overridden_by_client_ini", ",".join(overridden) if not overridden.is_empty() else "-"])
	return [
		["game", [["version", version["version"]], ["released", version["released"]], ["commit", version["commit"]]]],
		["godot", [["version", Engine.get_version_info().get("string", "?")],
			["double", "yes" if OS.has_feature("double") else "no"], ["os", "%s %s" % [OS.get_name(), OS.get_version()]],
			["arch", Engine.get_architecture_name()]]],
		["cpu", [["name", OS.get_processor_name()], ["threads", OS.get_processor_count()],
			["ram_gib", snappedf(float(memory.get("physical", 0)) / _GIB, 0.1)],
			["ram_free_gib", snappedf(float(memory.get("available", 0)) / _GIB, 0.1)]]],
		["gpu", [["name", RenderingServer.get_video_adapter_name()], ["vendor", RenderingServer.get_video_adapter_vendor()],
			["type", _ADAPTER_TYPES.get(RenderingServer.get_video_adapter_type(), "?")],
			["api", RenderingServer.get_video_adapter_api_version()],
			["driver", " ".join(OS.get_video_adapter_driver_info())]]],
		["renderer", [["method", RenderingServer.get_current_rendering_method()],
			["driver", RenderingServer.get_current_rendering_driver_name()]]],
		["display", [["window", "%dx%d" % [window.x, window.y]], ["mode", _window_mode()],
			["refresh_hz", roundi(DisplayServer.screen_get_refresh_rate())],
			["render3d", "%dx%d" % [roundi(window.x * scale), roundi(window.y * scale)]],
			["fov", roundi(SettingsManager.get_fov())]]],
		["caps", [["max_fps", caps.get("max_fps", 0)],
			["vsync", "on" if int(caps.get("vsync", 0)) != DisplayServer.VSYNC_DISABLED else "off"],
			["during_run", "lifted"]]],
		["graphics", graphics],
		["place", _place(player)],
	]


## Every SubViewport in the tree, with what decides whether it renders: {node, path, size, update,
## visible}. They are drawn on top of the root viewport and its GPU time does not include them, so a
## screen left rendering far away is invisible in every other number — hence this list.
static func subviewports(tree: SceneTree) -> Array[Dictionary]:
	var out : Array[Dictionary] = []
	for node in tree.root.find_children("*", "SubViewport", true, false):
		var vp := node as SubViewport
		var parent : Node = vp.get_parent()
		out.append({
			"node": vp,
			"path": str(tree.root.get_path_to(vp)),
			"size": "%dx%d" % [vp.size.x, vp.size.y],
			"update": _UPDATE_MODES.get(vp.render_target_update_mode, "?"),
			"visible": _shown(parent),
		})
	return out


## Whether what displays a SubViewport is shown: a 2D container, or the 3D node carrying the screen.
static func _shown(holder: Node) -> bool:
	if holder is CanvasItem:
		return (holder as CanvasItem).is_visible_in_tree()
	if holder is Node3D:
		return (holder as Node3D).is_visible_in_tree()
	return false


## {version, released, commit}. An installed build carries version.json beside the executable (the
## CI writes it); from the editor, the commit checked out says which code ran.
static func game_version() -> Dictionary:
	var out : Dictionary = {"version": "dev", "released": "-", "commit": "-"}
	var file : String = CapturePaths.game_dir().path_join("version.json")
	if FileAccess.file_exists(file):
		var parsed : Variant = JSON.parse_string(FileAccess.get_file_as_string(file))
		if parsed is Dictionary:
			out["version"] = str(parsed.get("version", "dev"))
			out["released"] = str(parsed.get("releaseDate", "-"))
	if OS.has_feature("editor"):
		out["commit"] = _git_commit(CapturePaths.game_dir().path_join(".git"))
	return out


static func _git_commit(git_dir: String) -> String:
	var head : String = FileAccess.get_file_as_string(git_dir.path_join("HEAD")).strip_edges()
	if not head.begins_with("ref: "):
		return head.left(8) if head != "" else "-"
	var ref : String = head.trim_prefix("ref: ")
	var hash : String = FileAccess.get_file_as_string(git_dir.path_join(ref)).strip_edges()
	return "%s@%s" % [ref.get_file(), hash.left(8)] if hash != "" else ref.get_file()


static func _place(player: Node3D) -> Array:
	if not is_instance_valid(player):
		return [["planet", "-"]]
	var planet : Planet = Planet.of(player)
	var others : int = maxi(0, player.get_tree().get_nodes_in_group("player").size() - 1)
	if planet == null:
		return [["planet", "-"], ["other_players", others]]
	var here : Vector3 = player.global_position
	var lonlat : Vector2 = planet.lonlat_of(here)
	# The local hour matters as much as the place: at night the atmosphere stops integrating at the
	# planet's shadow and costs a fraction of its daytime price (98 vs 60 fps measured at the same spot).
	var hour : float = planet.get_local_solar_time(here)
	return [["planet", planet.name], ["lat", snappedf(lonlat.y, 0.0001)], ["lon", snappedf(lonlat.x, 0.0001)],
		["elevation_m", roundi(planet.elevation_of(here))],
		["local_time", "%02d:%02d" % [int(hour), int(fmod(hour, 1.0) * 60.0)] if hour >= 0.0 else "-"],
		["other_players", others]]


static func _window_mode() -> String:
	match DisplayServer.window_get_mode():
		DisplayServer.WINDOW_MODE_FULLSCREEN:
			return "fullscreen"
		DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
			return "exclusive_fullscreen"
		DisplayServer.WINDOW_MODE_MAXIMIZED:
			return "maximized"
	return "windowed"


## Video memory in use, MiB.
static func vram_mib() -> int:
	return roundi(float(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)) / _MIB)
