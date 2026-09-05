class_name ClientConfig
extends RefCounted
## Reader for the hand-edited `client.ini` that sits next to the game executable.
##
## Every diagnostic switch in this project used to be a command-line flag (`--no-perf`,
## `--net-verbose`, `--net-echo`, `--rocks-*`). A player who runs a packaged build starts it from a
## shortcut, a launcher or a store client and CANNOT pass any of them — so the "I have 5 FPS"
## reports from the field kept arriving with exactly the log a healthy client produces (that is the
## whole reason client_perf.gd exists) and we could neither confirm nor rule out a hypothesis
## without shipping a new build first. This turns those flags into ini keys: the user edits one text
## file, restarts, plays, sends the log.
##
## Deliberately forgiving, because the person editing it is a player with Notepad, not a developer:
##   * the file is looked for in four places (working directory, next to the executable, user://,
##     res://) and the one that won is PRINTED at boot — "I set the key and nothing happened" is
##     otherwise unfalsifiable, and the working directory is not the executable's directory when the
##     game is started from a launcher;
##   * a key is accepted from ANY section, and from no section at all, so `debug_perf=true` typed on
##     the first line of the file works just as well as one placed under `[debug]`;
##   * booleans accept true/1/yes/on/oui and their quoted forms, since ConfigFile hands back a
##     String for `debug_perf=true` written without quotes in some hand-edited files.
##
## Only DIAGNOSTIC keys go through here. `[network] websocket_url` and `[chat] broker_url` keep
## their own local loads in client.gd / chat_network.gd: those run at connect time and must not
## depend on a cache warmed at boot.

## Read once, then cached: this is consulted from _static_init (RockDebug) and from autoload _ready
## callbacks, i.e. several times during the first frame.
static var _values: Dictionary = {}
static var _source: String = ""
static var _tried: PackedStringArray = []
static var _duplicates: PackedStringArray = []
static var _loaded: bool = false


## Where `client.ini` is looked for, in order; the first file that parses wins.
##
## "client.ini" (relative) is resolved by the OS against the CURRENT WORKING DIRECTORY, which is the
## executable's directory only when the game is launched from there. The explicit executable-dir
## candidate is what makes the documented "put client.ini next to the .exe" actually true for a
## shortcut or a launcher, and user:// is the fallback for an installation whose program directory
## is read-only (Program Files, /usr, a Flatpak).
static func _candidates() -> PackedStringArray:
	var out: PackedStringArray = ["client.ini"]
	var exe_dir: String = OS.get_executable_path().get_base_dir()
	if exe_dir != "":
		out.append(exe_dir.path_join("client.ini"))
	out.append("user://client.ini")
	out.append("res://client.ini")
	return out


static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	_tried = _candidates()
	var cfg: ConfigFile = ConfigFile.new()
	for path: String in _tried:
		if cfg.load(path) != OK:
			continue
		_source = path
		# Flattened on purpose: sections are a filing convenience for us and a trap for the user, who
		# has no way of knowing that a key only counts under the right header. A key typed anywhere
		# in the file is found. get_sections() includes the empty section for keys written before any
		# header, so `debug_perf=true` on line 1 is picked up too.
		for section: String in cfg.get_sections():
			for key: String in cfg.get_section_keys(section):
				var flat: String = key.strip_edges().to_lower()
				if _values.has(flat):
					_duplicates.append("%s (in [%s])" % [flat, section])
				_values[flat] = cfg.get_value(section, key)
		break


## The file that was actually read, or "" when there is none.
static func source() -> String:
	_load()
	return _source


## Where a user should create the file when there is none — the executable's directory, which is the
## one place they can reliably find. Printed in the "verbose is off" hint so a support answer can be
## a copy/paste instead of a conversation.
static func expected_path() -> String:
	_load()
	if _source != "":
		return _source
	var exe_dir: String = OS.get_executable_path().get_base_dir()
	return exe_dir.path_join("client.ini") if exe_dir != "" else "client.ini"


static func has_key(key: String) -> bool:
	_load()
	return _values.has(key.to_lower())


static func get_bool(key: String, fallback: bool) -> bool:
	_load()
	var v: Variant = _values.get(key.to_lower())
	if v == null:
		return fallback
	if v is bool:
		return v
	if v is int or v is float:
		return float(v) != 0.0
	# ConfigFile returns a String for an unquoted `debug_perf=true` in some hand-written files, and a
	# player may well type "yes", "on", "1" or "oui".
	var s: String = str(v).strip_edges().strip_escapes().to_lower().trim_prefix("\"").trim_suffix("\"")
	if s in ["true", "1", "yes", "y", "on", "oui", "vrai"]:
		return true
	if s in ["false", "0", "no", "n", "off", "non", "faux"]:
		return false
	return fallback


static func get_float(key: String, fallback: float) -> float:
	_load()
	var v: Variant = _values.get(key.to_lower())
	if v == null:
		return fallback
	if v is float or v is int:
		return float(v)
	var s: String = str(v).strip_edges().trim_prefix("\"").trim_suffix("\"")
	return s.to_float() if s.is_valid_float() else fallback


static func get_int(key: String, fallback: int) -> int:
	return int(get_float(key, float(fallback)))


static func get_string(key: String, fallback: String) -> String:
	_load()
	var v: Variant = _values.get(key.to_lower())
	if v == null:
		return fallback
	return str(v)


## Every key the file gave us, for the boot log. This is the line that answers "is the game reading
## the file I edited?" — the single most common failure of a hand-edited config, ahead of any typo
## in the values themselves.
static func boot_report() -> void:
	_load()
	if _source == "":
		print("[CConf] no client.ini found — looked in: %s" % " | ".join(_tried))
		return
	var parts: PackedStringArray = []
	for k: String in _values.keys():
		parts.append("%s=%s" % [k, str(_values[k])])
	parts.sort()
	print("[CConf] loaded %s (%d keys) | %s" % [_source, _values.size(), " ".join(parts)])
	if not _duplicates.is_empty():
		print("[CConf] WARNING duplicate keys, last one wins: %s" % " ".join(_duplicates))
