@tool
class_name SharedMaterialBuilder
extends RefCounted

## Generates the Godot resources of the shared PBR material library.
##
## Single responsibility: derive the Godot side of a material from its manifest.
## For every material.json it builds the sibling <id>.tres that
## SharedMaterialResolver loads at import time, and pins the import settings of
## the maps it declares.
##
## material.json is the source of truth, so both outputs are derived: never edit
## them by hand, regenerate them (DyingStar > Rebuild shared materials) — same
## rule as materials_library.blend on the Blender side.
##
## build(false) only compares: what is on disk against what the manifests give.
## That is the pull-request check (test_shared_material_library.gd), so nobody
## can merge a material.json whose resource was never regenerated. The
## comparison is made property by property, never on the file's text, so it
## reads the same on every system.
##
## Deliberately kept out of the import pipeline: a glTF exported with Images:
## None carries no textures, so an import has nothing to build a material from,
## and writing into res:// mid-import would trigger a filesystem rescan.

## The resolver owns the library layout: where materials live and where each
## one's resource sits. Writing through it guarantees the generator and the
## import-time lookup can never disagree about a path.
const Resolver := preload("res://addons/dyingstar/shared_material_resolver.gd")

const MANIFEST_NAME := "material.json"
const IMPORT_EXTENSION := ".import"

## Values of the "roughness/mode" import option, whose enum reads
## "Detect, Disabled, Red, Green, Blue, Alpha, Gray".
const ROUGHNESS_MODE_DISABLED := 1
const ROUGHNESS_MODE_RED := 2
const ROUGHNESS_MODE_GREEN := 3


## Outcome of a build pass, so the run reports without parsing logs.
class Report extends RefCounted:
	## Resources rewritten (build(true) only).
	var written: PackedStringArray = []
	## Resources missing or no longer what their manifest gives: written by build(true), reported by
	## build(false).
	var stale: PackedStringArray = []
	## Textures whose import settings were (or, in a check, would be) re-pinned.
	var repinned: PackedStringArray = []
	var warnings: PackedStringArray = []
	var errors: PackedStringArray = []

	## True when every resource and every import pin already matches its manifest.
	func is_up_to_date() -> bool:
		return stale.is_empty() and repinned.is_empty() and errors.is_empty()


## Builds every material of the library. With [param write] false nothing is written: the report says
## what is out of date.
func build(write: bool = true) -> Report:
	var report := Report.new()
	for folder_name in _list_material_folders(report):
		_build_material(folder_name, report, write)
	return report


## Whether two materials hold the same values, property by property. A texture counts as the same when
## it is the same file.
static func same_material(a: Material, b: Material) -> bool:
	if a == null or b == null or a.get_class() != b.get_class():
		return false
	for property in a.get_property_list():
		if not (int(property.usage) & PROPERTY_USAGE_STORAGE):
			continue
		var key: StringName = property.name
		if not _same_value(a.get(key), b.get(key)):
			return false
	return true


static func _same_value(a: Variant, b: Variant) -> bool:
	if a is Resource or b is Resource:
		if a == null or b == null:
			return a == b
		return (a as Resource).resource_path == (b as Resource).resource_path
	if typeof(a) != typeof(b):
		return false
	match typeof(a):
		TYPE_FLOAT:
			return is_equal_approx(a, b)
		TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4, TYPE_COLOR:
			return a.is_equal_approx(b)
	return a == b


func print_report(report: Report) -> void:
	print(
		"[DyingStar] %d material resource(s) written to %s"
		% [report.written.size(), Resolver.MATERIALS_DIR]
	)
	for path in report.written:
		print("[DyingStar]   %s" % path)
	# Godot owns when to act on a changed .import: the rebuild hands the re-pinned
	# textures to the same reimport as the models, never to a second one.
	print("[DyingStar] %d texture(s) re-pinned." % report.repinned.size())
	for message in report.warnings:
		push_warning("[DyingStar] %s" % message)
	for message in report.errors:
		push_error("[DyingStar] %s" % message)


func _list_material_folders(report: Report) -> PackedStringArray:
	var dir := DirAccess.open(Resolver.MATERIALS_DIR)
	if dir == null:
		report.errors.append("%s cannot be opened." % Resolver.MATERIALS_DIR)
		return PackedStringArray()
	return dir.get_directories()


func _build_material(folder_name: String, report: Report, write: bool) -> void:
	var folder_path := Resolver.MATERIALS_DIR.path_join(folder_name)
	var manifest_path := folder_path.path_join(MANIFEST_NAME)
	if not FileAccess.file_exists(manifest_path):
		return

	var manifest := _read_manifest(manifest_path)
	if manifest.is_empty():
		report.errors.append("%s is missing or is not valid JSON." % manifest_path)
		return

	# The id is the join key between Blender, the glTF, the folder and the
	# resource. A divergence here breaks the assignment silently, so it stops
	# the build rather than producing a resource nobody will ever load.
	var material_id := str(manifest.get("id", ""))
	if material_id != folder_name:
		report.errors.append(
			"%s declares id '%s'. The folder name and the id must match."
			% [manifest_path, material_id]
		)
		return

	_pin_import_settings(folder_path, manifest, report, write)

	var material := StandardMaterial3D.new()
	material.resource_name = material_id
	_apply_tiling(material, manifest, material_id, report)
	_apply_maps(material, folder_path, manifest, material_id, report)

	var output_path := Resolver.resource_path(material_id)
	if _matches_saved(material, output_path):
		return
	report.stale.append(output_path)
	if not write:
		return
	var save_error := ResourceSaver.save(material, output_path)
	if save_error != OK:
		report.errors.append("%s could not be written (error %d)." % [output_path, save_error])
		return
	report.written.append(output_path)


## Whether the resource on disk already holds what [param material] holds. Read past the cache: the
## file is what a pull request changes, not the copy an earlier load left in memory.
func _matches_saved(material: Material, path: String) -> bool:
	if not ResourceLoader.exists(path):
		return false
	var saved := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Material
	return same_material(material, saved)


func _read_manifest(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	return {}


## physical_size_m is the real-world size, in meters, covered by one UV tile.
## Models are unwrapped at 1 UV unit = 1 meter, so the material compresses the
## texture by the inverse to land at the intended scale. This is the same
## inversion the Mapping node applies in Blender: without it the model would
## tile differently in Godot than in the viewport it was authored in.
func _apply_tiling(
	material: StandardMaterial3D, manifest: Dictionary, material_id: String, report: Report
) -> void:
	var physical_size: Array = manifest.get("physical_size_m", [])
	if physical_size.size() != 2:
		report.warnings.append(
			"%s: physical_size_m is missing or malformed, tiling left at 1:1." % material_id
		)
		return

	var width := float(physical_size[0])
	var height := float(physical_size[1])
	if width <= 0.0 or height <= 0.0:
		report.warnings.append(
			"%s: physical_size_m must be positive, tiling left at 1:1." % material_id
		)
		return

	material.uv1_scale = Vector3(1.0 / width, 1.0 / height, 1.0)


# --- Import settings ----------------------------------------------------------
#
# Godot decides on its own which texture is a roughness map, by watching how
# materials sample it, and then points its roughness limiter at the normal map.
# The guess is unreliable: on this library it wired the limiter onto the ao and
# height maps, left the real roughness map on "Detect", and stored mode values
# outside the option's own 0-6 range.
#
# material.json already states what every map is, so the setting is written from
# the manifest instead of being detected.


func _pin_import_settings(
	folder_path: String, manifest: Dictionary, report: Report, write: bool
) -> void:
	var maps: Dictionary = manifest.get("maps", {})
	var normal_path := _map_path(folder_path, maps, "normal")

	for map_name in maps:
		var texture_path := _map_path(folder_path, maps, str(map_name))
		if texture_path.is_empty():
			continue

		var roughness_mode := _roughness_mode_for(str(map_name))
		# The limiter reads the normal map to know how much detail a mip level
		# loses. Without one there is nothing to limit against.
		if normal_path.is_empty():
			roughness_mode = ROUGHNESS_MODE_DISABLED

		var source_normal := normal_path if roughness_mode != ROUGHNESS_MODE_DISABLED else ""
		if _write_import_settings(texture_path, roughness_mode, source_normal, report, write):
			report.repinned.append(texture_path)


## The roughness limiter belongs on the map that carries roughness and nowhere
## else: a dedicated map holds it in red, a packed ORM map in green.
func _roughness_mode_for(map_name: String) -> int:
	match map_name:
		"roughness":
			return ROUGHNESS_MODE_RED
		"orm":
			return ROUGHNESS_MODE_GREEN
		_:
			return ROUGHNESS_MODE_DISABLED


## Returns true when the settings differ from the pinned ones (and, with [param write], were rewritten),
## so only the textures whose settings changed are reimported.
func _write_import_settings(
	texture_path: String, roughness_mode: int, source_normal: String, report: Report, write: bool
) -> bool:
	var import_path := texture_path + IMPORT_EXTENSION
	var config := ConfigFile.new()
	if config.load(import_path) != OK:
		report.warnings.append(
			"%s could not be read, its import settings are left untouched." % import_path
		)
		return false

	var current_mode: int = config.get_value("params", "roughness/mode", 0)
	var current_normal: String = config.get_value("params", "roughness/src_normal", "")
	if current_mode == roughness_mode and current_normal == source_normal:
		return false
	if not write:
		return true

	config.set_value("params", "roughness/mode", roughness_mode)
	config.set_value("params", "roughness/src_normal", source_normal)

	var save_error := config.save(import_path)
	if save_error != OK:
		report.errors.append("%s could not be written (error %d)." % [import_path, save_error])
		return false
	return true


func _map_path(folder_path: String, maps: Dictionary, map_name: String) -> String:
	var file_name := str(maps.get(map_name, ""))
	if file_name.is_empty():
		return ""
	var path := folder_path.path_join(file_name)
	if not FileAccess.file_exists(path):
		return ""
	return path


# --- Material resource --------------------------------------------------------


func _apply_maps(
	material: StandardMaterial3D,
	folder_path: String,
	manifest: Dictionary,
	material_id: String,
	report: Report
) -> void:
	var maps: Dictionary = manifest.get("maps", {})
	for map_name in maps:
		var file_name := str(maps[map_name])
		var texture := _load_texture(folder_path, file_name)
		if texture == null:
			report.warnings.append(
				"%s: %s not found, the %s map is skipped." % [material_id, file_name, map_name]
			)
			continue
		_assign_map(material, str(map_name), texture, material_id, report)


func _load_texture(folder_path: String, file_name: String) -> Texture2D:
	if file_name.is_empty():
		return null
	var path := folder_path.path_join(file_name)
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


func _assign_map(
	material: StandardMaterial3D,
	map_name: String,
	texture: Texture2D,
	material_id: String,
	report: Report
) -> void:
	match map_name:
		"albedo":
			material.albedo_texture = texture
		"normal":
			material.normal_enabled = true
			material.normal_texture = texture
		"roughness":
			material.roughness_texture = texture
		"metallic":
			material.metallic_texture = texture
			# The map is multiplied by the metallic scalar, which defaults to 0
			# and would cancel it out entirely.
			material.metallic = 1.0
		"ao":
			_assign_occlusion(material, texture, BaseMaterial3D.TEXTURE_CHANNEL_RED)
		"height":
			# Godot's heightmap slot drives parallax mapping, which displaces
			# UVs. In Blender the same map feeds a Bump node, which only
			# perturbs the normal. Wiring one to the other makes the surface
			# swim as the camera moves, and costs GPU for a look the material
			# was never authored for. The map stays in the library for a future
			# use that actually wants displacement.
			report.warnings.append(
				"%s: height is left unwired, Godot's slot is parallax, not bump."
				% material_id
			)
		"emissive":
			material.emission_enabled = true
			material.emission_texture = texture
		"orm":
			_assign_packed_orm(material, texture)
		"opacity":
			# StandardMaterial3D has no opacity slot: transparency is read from
			# the alpha channel of the albedo map. Supporting a separate opacity
			# file would mean merging it into the albedo at export time.
			report.warnings.append(
				"%s: a standalone opacity map is not supported, it is skipped." % material_id
			)
		_:
			report.warnings.append("%s: unknown map '%s', it is skipped." % [material_id, map_name])


## Occlusion darkens direct light as well as ambient.
##
## Godot defaults ao_light_affect to 0, where occlusion only dims ambient light.
## The library authors its materials in Blender, where the same map is
## multiplied into the base colour and therefore darkens everything. Left at the
## default, a material with strong occlusion comes out markedly brighter in
## Godot than in the viewport it was judged in.
func _assign_occlusion(
	material: StandardMaterial3D, texture: Texture2D, channel: int
) -> void:
	material.ao_enabled = true
	material.ao_texture = texture
	material.ao_texture_channel = channel
	material.ao_light_affect = 1.0


## A packed ORM map feeds three slots from one texture, each reading its own
## channel: occlusion in red, roughness in green, metalness in blue.
func _assign_packed_orm(material: StandardMaterial3D, texture: Texture2D) -> void:
	_assign_occlusion(material, texture, BaseMaterial3D.TEXTURE_CHANNEL_RED)

	material.roughness_texture = texture
	material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN

	material.metallic_texture = texture
	material.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
	material.metallic = 1.0
