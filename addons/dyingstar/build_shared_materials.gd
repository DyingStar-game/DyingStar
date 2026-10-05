@tool
extends EditorScript

## Kept so File > Run (Ctrl+Shift+X) on this script still works: it does exactly what the menu entry
## "DyingStar > Rebuild shared materials" does — regenerate the shared material library from its
## material.json files, then reimport the models that still show a library material unlinked (see
## shared_material_rebuild.gd; the generator itself is SharedMaterialBuilder).

const Rebuild := preload("res://addons/dyingstar/shared_material_rebuild.gd")


func _run() -> void:
	Rebuild.new().run()
