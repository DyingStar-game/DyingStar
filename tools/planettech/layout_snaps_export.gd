extends Node
## Writes assets/qgis/export/layout_snaps.json (LayoutSnaps): the footprint and the road snaps of
## every village and city layout, for the QGIS road export. Run it after moving a building or a
## RoadSnap in a layout, then re-export the roads (export_roads.py): test_layout_snaps fails until then.
##
##   godot --headless --path . res://tools/planettech/layout_snaps_export.tscn
##
## A scene and not a SceneTree script: the layouts' buildings need the autoloads to load.


func _ready() -> void:
	var path := ProjectSettings.globalize_path(LayoutSnaps.EXPORT_PATH)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("cannot write %s" % path)
		get_tree().quit(1)
		return
	f.store_string(LayoutSnaps.to_json())
	f.close()
	print("written %s" % path)
	get_tree().quit()
