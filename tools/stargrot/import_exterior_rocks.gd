extends Node
## Bake the dedicated exterior set; never rebuild the six interior meshes.

const DIRECTORY := "res://scenes/planet/cave/assets/rock_exterior/"
const LIBRARY := "res://scenes/planet/cave/libraries/cave_rock_exterior.tres"


func _ready() -> void:
    var material: StandardMaterial3D = load(DIRECTORY + "exterior_material.tres")
    var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DIRECTORY + "manifest.json"))
    var library := CaveAssetLibrary.new()
    library.library_id = "rock_exterior_v1"
    library.display_name = "Rochers extérieurs — fractures, dalles et affleurements"
    library.instance_budget = 180
    for item: Dictionary in manifest.assets:
        var id: String = item.id
        var packed: PackedScene = load(DIRECTORY + id + ".glb")
        var root := packed.instantiate()
        var instance: MeshInstance3D = root.find_children("*", "MeshInstance3D", true, false)[0]
        var mesh: ArrayMesh = instance.mesh.duplicate()
        mesh.resource_name = id
        for surface in mesh.get_surface_count():
            mesh.surface_set_material(surface, material)
        _save(mesh, DIRECTORY + id + ".tres")
        var collision := mesh.create_convex_shape(true, true)
        _save(collision, DIRECTORY + id + "_collision.tres")
        for support in ["entrance_ground", "entrance_wall"]:
            var rule := CaveDecorationRule.new()
            rule.rule_name = ("ground_" if support == "entrance_ground" else "wall_") + id
            rule.mesh = mesh
            rule.material = material
            rule.collision_shape = collision
            rule.support = support
            rule.zone = "entrance"
            rule.distribution = "clustered"
            rule.spacing_m = 2.0
            rule.scale_min = 0.35 if support == "entrance_ground" else 0.5
            rule.scale_max = 1.2 if support == "entrance_ground" else 1.65
            rule.max_instances = 5 if support == "entrance_ground" else 7
            var box := mesh.get_aabb()
            rule.radius_m = ceilf(maxf(maxf(absf(box.position.x), absf(box.end.x)),
                maxf(absf(box.position.z), absf(box.end.z))) * 100.0) / 100.0
            library.decorations.append(rule)
        root.free()
    assert(library.validation_error().is_empty(), library.validation_error())
    _save(library, LIBRARY)
    print("STARGROT EXTERIOR IMPORT meshes=", manifest.assets.size(), " rules=", library.decorations.size())
    get_tree().quit()


func _save(resource: Resource, path: String) -> void:
    var error := ResourceSaver.save(resource, path)
    assert(error == OK, "Cannot save %s: %s" % [path, error_string(error)])
    resource.take_over_path(path)
