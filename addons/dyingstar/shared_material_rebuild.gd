@tool
extends RefCounted

## "DyingStar > Rebuild shared materials": the whole chore after adding or changing a material.json, in
## one go. (File > Run on build_shared_materials.gd does the same.)
##
## 1. SharedMaterialBuilder regenerates the library's resources and pins the import settings of its
##    textures.
## 2. The models imported before one of their library materials existed are found and reimported: the
##    import script links only what exists at import time, so a reimport is what links them.
##
## The re-pinned textures and those models go to ONE reimport, once any filesystem scan has ended: two
## at once is what Godot refuses ("Task 'reimport' already exists"). Within one reimport the textures
## are imported before the scenes, by importer order.

const Resolver := preload("res://addons/dyingstar/shared_material_resolver.gd")
## The import script that links library materials: a model is concerned only when its import uses it.
const IMPORT_SCRIPT := "res://addons/dyingstar/post_import_shared_materials.gd"
## Extensions of the models the import script runs on.
const MODEL_EXTENSIONS: PackedStringArray = ["glb", "gltf"]


func run() -> void:
	var builder := SharedMaterialBuilder.new()
	var report: SharedMaterialBuilder.Report = builder.build(true)
	var filesystem := EditorInterface.get_resource_filesystem()
	# update_file() rather than a full scan(): a scan queues a project-wide reimport, which collides with
	# the one Godot starts on its own when a texture is first used in 3D.
	for path in report.written:
		filesystem.update_file(path)
	builder.print_report(report)

	var models := unlinked_models()
	print("[DyingStar] %d model(s) to relink by a reimport" % models.size())
	for path in models:
		print("[DyingStar]   %s" % path)
	var to_reimport := PackedStringArray(report.repinned)
	to_reimport.append_array(models)
	if to_reimport.is_empty():
		return
	var reimport := filesystem.reimport_files.bind(to_reimport)
	if filesystem.is_scanning():
		filesystem.filesystem_changed.connect(reimport, CONNECT_ONE_SHOT)
	else:
		reimport.call_deferred()


## Every model whose import links library materials and that still shows one of them unlinked.
func unlinked_models() -> PackedStringArray:
	var resolver := Resolver.new()
	var models := PackedStringArray()
	for path in _models_using_import_script(EditorInterface.get_resource_filesystem().get_filesystem()):
		var packed := ResourceLoader.load(path) as PackedScene
		if packed == null:
			continue
		var scene := packed.instantiate()
		if not resolver.unlinked(scene).is_empty():
			models.append(path)
		scene.free()
	return models


func _models_using_import_script(dir: EditorFileSystemDirectory) -> PackedStringArray:
	var found := PackedStringArray()
	for i in dir.get_file_count():
		var path := dir.get_file_path(i)
		if path.get_extension().to_lower() in MODEL_EXTENSIONS and imports_with_script(path):
			found.append(path)
	for i in dir.get_subdir_count():
		found.append_array(_models_using_import_script(dir.get_subdir(i)))
	return found


## Whether a model's .import names the shared-material import script, by path or by uid (the project's
## import defaults write the uid).
static func imports_with_script(model_path: String) -> bool:
	var config := ConfigFile.new()
	if config.load(model_path + ".import") != OK:
		return false
	var script := str(config.get_value("params", "import_script/path", ""))
	if script.begins_with("uid://"):
		var id := ResourceUID.text_to_id(script)
		script = ResourceUID.get_id_path(id) if ResourceUID.has_id(id) else ""
	return script == IMPORT_SCRIPT
