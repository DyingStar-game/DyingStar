class_name CaveAuthoringFile
extends RefCounted
## Authored content must report failed replacement, even when the old destination exists.


static func save(resource: Resource, path: String) -> Error:
    var absolute := ProjectSettings.globalize_path(path)
    var staged := AtomicFile.temp_path(absolute)
    var error := ResourceSaver.save(resource, staged)
    if error == OK:
        error = DirAccess.rename_absolute(staged, absolute)
    if error != OK:
        DirAccess.remove_absolute(staged)
    return error
