extends Node
## Bake imported glTF meshes into shared native resources. Run this scene after Blender export/import.

const DIRECTORY := "res://scenes/planet/cave/assets/rock_stylized/"
const LIBRARIES := "res://scenes/planet/cave/libraries/"
const IDS := ["rock_boulder_01", "rock_boulder_02", "rock_boulder_03", "rock_rubble_01",
    "rock_stalagmite_01", "rock_stalactite_01"]


func _ready() -> void:
    _run.call_deferred()


func _run() -> void:
    # The authored native material survives model rebakes (Rock029 textures and vertex tint).
    var material: StandardMaterial3D = load(DIRECTORY + "rock_shared_material.tres")
    var authored: CaveAssetLibrary = load(LIBRARIES + "cave_rock_sculpted.tres")
    var exterior := authored.entrance_library
    var rules: Array[CaveDecorationRule] = []
    for index in IDS.size():
        var id: String = IDS[index]
        var packed: PackedScene = load(DIRECTORY + id + ".glb")
        var root := packed.instantiate()
        var instance: MeshInstance3D = root.find_children("*", "MeshInstance3D", true, false)[0]
        var mesh: ArrayMesh = instance.mesh.duplicate()
        mesh.resource_name = id
        for surface in mesh.get_surface_count():
            mesh.surface_set_material(surface, material)
        _save(mesh, DIRECTORY + id + ".tres")
        var rule := CaveDecorationRule.new()
        rule.rule_name = id
        rule.mesh = mesh
        rule.material = material
        rule.zone = "all" if index == 3 else ("deep" if index == 5 else "chamber")
        rule.support = "ceiling" if index == 5 else "floor"
        rule.distribution = "clustered" if index == 3 else "scattered"
        rule.align_to_surface = index < 4
        rule.max_slope_deg = 14 if index == 4 else (55 if index == 5 else 38)
        var box := mesh.get_aabb()
        rule.radius_m = ceilf(maxf(maxf(absf(box.position.x), absf(box.end.x)),
            maxf(absf(box.position.z), absf(box.end.z))) * 100.0) / 100.0
        rule.spacing_m = 8.0 if index < 3 else 6.0
        rule.scale_min = 0.7 if index < 4 else 0.6
        rule.scale_max = 1.3 if index < 4 else 1.1
        rule.max_instances = 12 if index < 3 else 28
        if index < 3:
            rule.collision_shape = mesh.create_convex_shape(true, true)
            _save(rule.collision_shape, DIRECTORY + id + "_collision.tres")
        rules.append(rule)
        root.free()
    var library := CaveAssetLibrary.new()
    library.library_id = "rock_sculpted_detail_v1"
    library.display_name = "Roche sculptée — salles et profondeur"
    library.surface_family = "rock"
    library.wall_material = load(LIBRARIES + "gabarits/rock_wall.tres")
    library.floor_material = load(LIBRARIES + "gabarits/rock_floor.tres")
    library.entrance_library = exterior
    library.decorations = rules
    library.instance_budget = 180
    assert(library.validation_error().is_empty(), library.validation_error())
    _save(library, LIBRARIES + "cave_rock_sculpted.tres")
    var mouth: CaveAssetLibrary = library.duplicate()
    mouth.library_id = "rock_sculpted_open_v1"
    mouth.display_name = "Roche sculptée — bouche ouverte"
    mouth.decorations = []
    for index in rules.size():
        var rule: CaveDecorationRule = rules[index].duplicate()
        if index < 3:
            rule.zone = "entrance"
            rule.scale_max = 1.8
            rule.max_instances = 10
        mouth.decorations.append(rule)
    _save(mouth, LIBRARIES + "cave_rock_sculpted_open.tres")
    print("STARGROT ROCK IMPORT six meshes, three convex colliders, two libraries")
    get_tree().quit()


func _save(resource: Resource, path: String) -> void:
    var error := ResourceSaver.save(resource, path)
    assert(error == OK, "Cannot save %s: %s" % [path, error_string(error)])
    resource.take_over_path(path)
