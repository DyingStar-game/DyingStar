class_name BuildInfo
extends RefCounted

## The id of this exported build, written into the pack by the DyingStar editor
## plugin (addons/dyingstar/build_id_export.gd) at each export. Every export gets
## its own: a server, a Linux client and a Windows client built from the same
## commit do not share it. Keys caches that a new build must never inherit (the
## terrain chunk cache). Empty in the editor and in tests: nothing was exported.

const PATH := "res://build_id.json"

static var _id: Variant = null


## This build's id ("" when not an exported build), read once.
static func build_id() -> String:
	if _id == null:
		_id = ""
		if FileAccess.file_exists(PATH):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
			if parsed is Dictionary:
				_id = str((parsed as Dictionary).get("build_id", ""))
	return _id


## The version a build shows and reports: the project's own, then this export's id when it has one,
## which tells two builds of one version apart ("0.0.1-dev · 20261117-1250-551351").
static func version_text() -> String:
	var version: String = str(ProjectSettings.get_setting("application/config/version", ""))
	if version == "":
		version = "?"
	if build_id() != "":
		version += " · " + build_id()
	return version


## A new id: the local date and time of the export, then a random number —
## "20261010-1432-048213".
static func make_build_id() -> String:
	var t := Time.get_datetime_dict_from_system()
	return "%04d%02d%02d-%02d%02d-%06d" % [t.year, t.month, t.day, t.hour, t.minute,
			randi() % 1000000]
