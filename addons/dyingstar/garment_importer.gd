@tool
extends EditorImportPlugin

## Imports a garment file (`<id>.dsgarment`, exported by the Blender add-on dyingstar_garments) into a
## HumanAssetData the game loads by its path (GarmentFormat.path_of). Its textures are the files beside it
## named `<id>_albedo`, `_normal`, `_ao`, `_tint` (.webp or .png).
##
## A garment hangs on body vertices by their index: one bound to another body (an older bank) would tear.
## Its body signature must be the bank's, or the import fails with the reason in the Output panel.

static var _bank_signature: String = ""


func _get_importer_name() -> String:
	return "dyingstar.garment"


func _get_visible_name() -> String:
	return "DyingStar garment"


func _get_recognized_extensions() -> PackedStringArray:
	return PackedStringArray([GarmentFormat.EXTENSION])


func _get_save_extension() -> String:
	return "res"


func _get_resource_type() -> String:
	return "Resource"


func _get_preset_count() -> int:
	return 1


func _get_preset_name(_preset_index: int) -> String:
	return "Default"


func _get_import_options(_path: String, _preset_index: int) -> Array[Dictionary]:
	return []


func _get_option_visibility(_path: String, _option_name: StringName, _options: Dictionary) -> bool:
	return true


func _get_priority() -> float:
	return 1.0


## After the textures (order 0): the garment refers to them.
func _get_import_order() -> int:
	return 100


func _import(source_file: String, save_path: String, _options: Dictionary, _platform_variants: Array[String],
		_gen_files: Array[String]) -> Error:
	var meta: Dictionary = {}
	var asset: HumanAssetData = GarmentFormat.read(source_file, meta)
	if asset == null:
		return ERR_PARSE_ERROR
	var expected: String = _signature()
	if expected != "" and asset.body_signature != expected:
		push_error(("garment %s was bound to body %s, the bank's is %s: bind it again on the current reference body "
			+ "(tools/character/garments/README.md)") % [source_file, asset.body_signature, expected])
		return ERR_INVALID_DATA
	for role in GarmentFormat.TEXTURE_ROLES:
		var path: String = GarmentFormat.texture_path(source_file, role, str(meta.get("textures", "")))
		if path == "":
			continue
		var texture: Texture2D = load(path)
		match role:
			"albedo":
				asset.albedo = texture
			"normal":
				asset.normal = texture
			"ao":
				asset.ao = texture
			"tint":
				asset.tint_mask = texture
	if asset.albedo == null:
		push_warning("garment %s has no %s beside it: it will be drawn plain" % [
			source_file, source_file.get_basename().get_file() + "_albedo.webp"])
	return ResourceSaver.save(asset, "%s.%s" % [save_path, _get_save_extension()], ResourceSaver.FLAG_COMPRESS)


func _signature() -> String:
	if _bank_signature == "" and ResourceLoader.exists(HumanBank.PATH):
		var bank: HumanBank = load(HumanBank.PATH)
		if bank != null:
			_bank_signature = GarmentFormat.bank_signature(bank)
	return _bank_signature
