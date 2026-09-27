class_name CapturePaths
extends RefCounted
## Where the client's captures land, and what they are called. Shared by the F6 recorder and the F7
## screenshot, so the two can never disagree on a file name or on what "the game folder" means.


## A file-name-safe timestamp: "2026-09-27T14-05-33" (Windows refuses ":" in a file name).
static func stamp() -> String:
	return Time.get_datetime_string_from_system().replace(":", "-")


## Documents/DyingStar/<sub>, created if missing. Always writable, and the same in the editor and in
## an installed build.
static func documents_dir(sub: String) -> String:
	var dir: String = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS).path_join("DyingStar").path_join(sub)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


## <game folder>/screenshots[/<sub>], where the game folder is the one holding the executable in
## an installed build, and the PROJECT folder when running from the editor (the executable there is
## the editor's, somewhere under Godot/). Falls back to Documents/DyingStar/screenshots[/<sub>] when
## that folder cannot be written — an install under Program Files, a read-only share.
## The F7 shots go at the top, the F6 recordings in the "records" sub-folder.
static func screenshots_dir(sub: String = "") -> String:
	var rel: String = "screenshots" if sub == "" else "screenshots".path_join(sub)
	var dir: String = game_dir().path_join(rel)
	if _writable(dir):
		return dir
	return documents_dir(rel)


## Open the screenshot folder in the OS file manager (Explorer, Finder, the Linux one) — the
## "Gallery" button of Settings > Video. Created first, so the button works before the first shot.
static func open_gallery() -> void:
	OS.shell_show_in_file_manager(screenshots_dir(), true)


static func game_dir() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://").trim_suffix("/")
	return OS.get_executable_path().get_base_dir()


## Tries it for real: a folder can exist and still refuse files, and only writing one says so.
static func _writable(dir: String) -> bool:
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		return false
	var probe: String = dir.path_join(".write_test")
	var f: FileAccess = FileAccess.open(probe, FileAccess.WRITE)
	if f == null:
		return false
	f.close()
	DirAccess.remove_absolute(probe)
	return true
