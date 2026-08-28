@tool
extends EditorScenePostImport

## Applies the project's shared materials every time a glTF is imported.
##
## Single responsibility: hook the import pipeline and report. The actual work
## lives in SharedMaterialResolver.
##
## Attached to a .glb through the Import dock (Import Script field), it runs on
## every reimport. That matters: Godot regenerates the imported scene whenever
## the source file changes, so anything assigned by hand in the editor would be
## silently lost at the next export from Blender. Doing it here makes the
## assignment part of the import itself.

const Resolver := preload("res://addons/dyingstar/shared_material_resolver.gd")


func _post_import(scene: Node) -> Object:
	var report: Resolver.Report = Resolver.new().resolve(scene)
	_report(scene, report)
	return scene


func _report(scene: Node, report: Resolver.Report) -> void:
	var source := get_source_file()

	if report.resolved > 0:
		print("[DyingStar] %s: %s" % [source.get_file(), report.to_string_summary()])

	for material_name in report.missing:
		push_warning(
			"[DyingStar] %s: shared material '%s' not found in %s. "
			% [source.get_file(), material_name, Resolver.MATERIALS_DIR]
			+ "The glTF material is kept as-is."
		)

	for material_name in report.embedded_textures:
		push_warning(
			"[DyingStar] %s: '%s' arrived with embedded textures. "
			% [source.get_file(), material_name]
			+ "Re-export from Blender with Material: Export and Images: None."
		)
