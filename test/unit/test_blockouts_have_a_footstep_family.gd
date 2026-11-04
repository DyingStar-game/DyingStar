extends GutTest
## Every CSG blockout one can walk on (use_collision) in the structures answers SurfaceProbe with a
## family the footsteps have sounds for: the teleporter's blockout had no material at all and played
## the error marker.

const ROOT := "res://scenes/_universe/structures/"
const FOOTSTEPS := "res://scenes/common/footsteps.tres"


func _scenes(dir: String, out: Array[String]) -> void:
	for f: String in DirAccess.get_files_at(dir):
		if f.ends_with(".tscn") and FileAccess.get_file_as_string(dir + f).contains("use_collision = true"):
			out.append(dir + f)
	for d: String in DirAccess.get_directories_at(dir):
		_scenes(dir + d + "/", out)


func test_every_walkable_blockout_has_a_footstep_family() -> void:
	var sounds := FileAccess.get_file_as_string(FOOTSTEPS)
	var scenes: Array[String] = []
	_scenes(ROOT, scenes)
	assert_gt(scenes.size(), 20, "the structures were read")
	for path: String in scenes:
		var root: Node = load(path).instantiate()
		add_child_autofree(root)
		var shapes: Array = root.find_children("*", "CSGShape3D", true, false).filter(
				func(s: Node) -> bool: return (s as CSGShape3D).use_collision and (s as CSGShape3D).is_root_shape())
		for s: CSGShape3D in shapes:
			var families := {}
			for m: Node in SurfaceProbe._meshes_near(s):
				var fam := SurfaceProbe.family_of_material(SurfaceProbe._surface_material(m as GeometryInstance3D))
				if fam != &"":
					families[fam] = true
			assert_gt(families.size(), 0, "%s %s: a material with a family" % [path.get_file(), s.name])
			for fam: StringName in families:
				assert_true(sounds.contains('&"%s"' % fam), "%s %s: footsteps for %s" % [path.get_file(), s.name, fam])
	KnownEngineErrors.forgive_floor_material(self)
