extends RefCounted
## Isolate saves and native caches before constructing test planets.

static func use_directory(name: String) -> void:
    var previous := OS.get_user_data_dir()
    ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
    ProjectSettings.set_setting("application/config/custom_user_dir_name", name)
    var current := OS.get_user_data_dir()
    DirAccess.make_dir_recursive_absolute(current)
    # The renderer initialized its folder tree before this scene changed user://.
    # Mirror directories only so later shader-cache writes have valid parents.
    if previous != current:
        _directories(previous.path_join("shader_cache"), current.path_join("shader_cache"))


static func _directories(source: String, target: String) -> void:
    if not DirAccess.dir_exists_absolute(source): return
    DirAccess.make_dir_recursive_absolute(target)
    for folder in DirAccess.get_directories_at(source):
        _directories(source.path_join(folder), target.path_join(folder))
