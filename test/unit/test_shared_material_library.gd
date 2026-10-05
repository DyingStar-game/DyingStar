extends GutTest
## The shared material library is generated from its material.json files (DyingStar > Rebuild shared
## materials). A pull request that changes a manifest without regenerating fails here: CI runs this
## suite as a blocking step, right after importing the project.

const Resolver := preload("res://addons/dyingstar/shared_material_resolver.gd")
const Rebuild := preload("res://addons/dyingstar/shared_material_rebuild.gd")
const LIBRARY_TEXTURE := "res://assets/_universe/_shared/materials/mat_metal_yellow_rusty/tex_metal_yellow_rusty_albedo.png"
const LIBRARY_MATERIAL := "mat_metal_yellow_rusty"


func test_the_shipped_library_matches_its_manifests() -> void:
	var report: SharedMaterialBuilder.Report = SharedMaterialBuilder.new().build(false)
	assert_eq(report.errors, PackedStringArray(), "every manifest builds")
	var out_of_date: PackedStringArray = report.stale + report.repinned
	assert_eq(out_of_date.size(), 0,
			"out of date: run DyingStar > Rebuild shared materials and commit what it changes:\n"
			+ "\n".join(out_of_date))


func test_a_check_writes_nothing() -> void:
	var report: SharedMaterialBuilder.Report = SharedMaterialBuilder.new().build(false)
	assert_eq(report.written.size(), 0)


func test_two_materials_are_compared_by_value_and_by_texture_file() -> void:
	var built := StandardMaterial3D.new()
	var saved := StandardMaterial3D.new()
	assert_true(SharedMaterialBuilder.same_material(built, saved))
	saved.uv1_scale = Vector3(0.5, 0.5, 1.0)
	assert_false(SharedMaterialBuilder.same_material(built, saved), "a tiling change is a change")
	saved.uv1_scale = built.uv1_scale
	built.albedo_texture = load(LIBRARY_TEXTURE)
	assert_false(SharedMaterialBuilder.same_material(built, saved), "a texture that went missing")
	saved.albedo_texture = load(LIBRARY_TEXTURE)
	assert_true(SharedMaterialBuilder.same_material(built, saved), "the same file is the same texture")
	saved.albedo_texture = ImageTexture.new()
	assert_false(SharedMaterialBuilder.same_material(built, saved), "another texture is a change")


## The import script links only what exists at import time: a model imported before its material
## shows the glTF's own material until it is reimported, and the rebuild finds it.
func test_a_model_imported_before_its_material_shows_it_unlinked() -> void:
	var model := _model_with(LIBRARY_MATERIAL)
	var resolver := Resolver.new()
	assert_eq(resolver.unlinked(model), PackedStringArray([LIBRARY_MATERIAL]))
	resolver.resolve(model)
	assert_eq(resolver.unlinked(model).size(), 0, "linked once the import script has run")
	model.free()


func test_a_name_the_library_lacks_is_never_unlinked() -> void:
	for material_name: String in ["mat_not_in_the_library", "wood_plank"]:
		var model := _model_with(material_name)
		assert_eq(Resolver.new().unlinked(model).size(), 0, "%s: a reimport would not link it" % material_name)
		model.free()


func test_models_are_found_by_their_import_script() -> void:
	assert_true(Rebuild.imports_with_script("res://assets/_universe/structures/industrial/garage.glb"),
			"named by uid, as the import defaults write it")
	assert_false(Rebuild.imports_with_script("res://assets/_universe/characters/humanoids/man_ddurieux.glb"),
			"another import script")


## A one-triangle model whose surface carries a glTF material of that name.
func _model_with(material_name: String) -> Node3D:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.add_vertex(Vector3.ZERO)
	surface.add_vertex(Vector3.RIGHT)
	surface.add_vertex(Vector3.UP)
	var material := StandardMaterial3D.new()
	material.resource_name = material_name
	surface.set_material(material)
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = surface.commit()
	var model := Node3D.new()
	model.add_child(mesh_instance)
	return model
