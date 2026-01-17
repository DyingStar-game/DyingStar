extends MainLoop
## Headless tool: converts all .recipe.json files to .recipe.bin
## using Godot's native variant serialisation (store_var / get_var).
##
## Usage (from the project root):
##   godot --headless --script res://tools/convert_recipes_binary.gd
##
## Reads the planet list from server.ini [prebake] planets="p1,p2,...".
## For each planet, scans assets/qgis/.export/{planet}_chunks/base_*/ and
## converts every .recipe.json that does not already have an up-to-date
## .recipe.bin companion.

const CONFIG_PATH := "res://server.ini"


func _initialize() -> void:
	print("[RecipeBin] Starting recipe binary conversion ...")

	# Optional --planet <name> (repeatable) to restrict conversion to specific
	# planets, bypassing server.ini. Used by tools/qgis/export_planet.py so an
	# export of a single planet does not iterate all prebake planets.
	var planets := _read_planet_override()
	if planets.is_empty():
		planets = _read_planet_list()
	if planets.is_empty():
		printerr("[RecipeBin] No planets configured in server.ini [prebake] section.")
		return

	print("[RecipeBin] Planets: %s" % [", ".join(planets)])

	var grand_total := 0
	var grand_skipped := 0
	var t_start := Time.get_ticks_msec()

	for planet_name in planets:
		var result := _convert_planet(planet_name)
		grand_total += result[0]
		grand_skipped += result[1]

	var elapsed := Time.get_ticks_msec() - t_start
	print("[RecipeBin] Done — converted %d recipes, skipped %d already up-to-date  (%.1fs)" % [
		grand_total, grand_skipped, elapsed / 1000.0])


func _process(_delta: float) -> bool:
	return true


# ------------------------------------------------------------------
# Read server.ini
# ------------------------------------------------------------------

func _read_planet_override() -> PackedStringArray:
	# Parse `--planet <name>` occurrences from user CLI args.
	var result := PackedStringArray()
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var a := args[i]
		if a == "--planet" and i + 1 < args.size():
			var name := args[i + 1].strip_edges()
			if not name.is_empty():
				result.append(name)
			i += 2
		elif a.begins_with("--planet="):
			var name_eq := a.substr("--planet=".length()).strip_edges()
			if not name_eq.is_empty():
				result.append(name_eq)
			i += 1
		else:
			i += 1
	return result

func _read_planet_list() -> PackedStringArray:
	var cfg := ConfigFile.new()
	var err := cfg.load(CONFIG_PATH)
	if err != OK:
		printerr("[RecipeBin] Failed to load %s: %d" % [CONFIG_PATH, err])
		return PackedStringArray()

	var raw: String = cfg.get_value("prebake", "planets", "")
	if raw.is_empty():
		return PackedStringArray()

	var result := PackedStringArray()
	for part in raw.split(","):
		var trimmed := part.strip_edges()
		if not trimmed.is_empty():
			result.append(trimmed)
	return result


# ------------------------------------------------------------------
# Convert one planet
# ------------------------------------------------------------------

## Returns [converted_count, skipped_count].
func _convert_planet(planet_name: String) -> Array:
	var chunks_dir := "res://assets/qgis/.export/%s_chunks" % planet_name
	var converted := 0
	var skipped := 0

	# Iterate base_0 .. base_11
	for base_idx in range(12):
		var base_dir := "%s/base_%d" % [chunks_dir, base_idx]
		if not DirAccess.dir_exists_absolute(base_dir):
			continue

		var dir := DirAccess.open(base_dir)
		if dir == null:
			continue

		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if file_name.ends_with(".recipe.json"):
				var stem := file_name.substr(0, file_name.length() - ".recipe.json".length())
				var json_path := "%s/%s" % [base_dir, file_name]
				var bin_path := "%s/%s.recipe.bin" % [base_dir, stem]

				# Skip if binary already exists and is newer than JSON
				if FileAccess.file_exists(bin_path):
					var json_mod := FileAccess.get_modified_time(json_path)
					var bin_mod := FileAccess.get_modified_time(bin_path)
					if bin_mod >= json_mod:
						skipped += 1
						file_name = dir.get_next()
						continue

				if _convert_one(json_path, bin_path):
					converted += 1
			file_name = dir.get_next()
		dir.list_dir_end()

	if converted > 0 or skipped > 0:
		print("[RecipeBin] %s: converted %d, skipped %d" % [planet_name, converted, skipped])
	else:
		print("[RecipeBin] %s: no recipe files found" % planet_name)
	return [converted, skipped]


# ------------------------------------------------------------------
# Convert a single file
# ------------------------------------------------------------------

func _convert_one(json_path: String, bin_path: String) -> bool:
	var fa := FileAccess.open(json_path, FileAccess.READ)
	if fa == null:
		printerr("[RecipeBin] Cannot open %s" % json_path)
		return false
	var text := fa.get_as_text()
	fa.close()

	var json := JSON.new()
	if json.parse(text) != OK:
		printerr("[RecipeBin] JSON parse error in %s: %s" % [json_path, json.get_error_message()])
		return false

	var recipe: Dictionary = json.data
	if recipe.is_empty():
		printerr("[RecipeBin] Empty recipe in %s" % json_path)
		return false

	var out := FileAccess.open(bin_path, FileAccess.WRITE)
	if out == null:
		printerr("[RecipeBin] Cannot write %s" % bin_path)
		return false
	out.store_var(recipe, false)
	out.close()
	return true
