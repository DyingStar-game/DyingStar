extends Node
## Bake the corundum crystal clusters (CaveCrystalMesh) into shared mesh resources. Run this scene after
## changing the generator or a seed; test_cave_crystal_mesh fails while the baked files are stale.
##   godot --headless --path . res://tools/stargrot/bake_crystal_assets.tscn

const DIRECTORY := "res://scenes/planet/cave/assets/crystal_corundum/"


func _ready() -> void:
    _run.call_deferred()


func _run() -> void:
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIRECTORY))
    for kind: String in CaveMineral.CRYSTAL_SEEDS:
        var mesh := CaveCrystalMesh.cluster(kind, CaveMineral.CRYSTAL_SEEDS[kind])
        mesh.resource_name = "corundum_cluster_" + kind
        var path := DIRECTORY + mesh.resource_name + ".tres"
        var error := ResourceSaver.save(mesh, path)
        print("[bake_crystal_assets] %s → %s (%d triangles, %s)" % [kind, path,
            mesh.surface_get_array_len(0) / 3, error_string(error)])
    get_tree().quit()
