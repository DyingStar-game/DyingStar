extends GutTest
## The road snaps of the village and city layouts (RoadSnap), and the file the QGIS road export reads
## them from (LayoutSnaps, assets/qgis/export/layout_snaps.json). A road export run on a stale file
## would cut the roads out of last week's footprint and lead them to a snap that has moved.

const TOOL := "godot --headless --path . res://tools/planettech/layout_snaps_export.tscn"


func test_the_exported_file_is_current() -> void:
	var on_disk := FileAccess.get_file_as_string(LayoutSnaps.EXPORT_PATH)
	assert_eq(on_disk, LayoutSnaps.to_json(), "a layout or a snap moved: run  %s  then export_roads.py" % TOOL)
	KnownEngineErrors.forgive_floor_material(self)  # the layouts' buildings load the floor material


func test_every_layout_has_a_way_in() -> void:
	var all := LayoutSnaps.all()
	assert_gte(all.size(), 2, "the mining village and the factory city")
	for path: String in all:
		var snaps: Array = all[path]["snaps"]
		assert_gt(snaps.size(), 0, "%s: a road must be able to reach it" % path.get_file())


func test_each_snap_stands_on_the_footprint_edge_facing_out() -> void:
	var all := LayoutSnaps.all()
	for path: String in all:
		var fp: Dictionary = all[path]["footprint"]
		var centre := Vector2(float(fp["cx"]), float(fp["cz"]))
		var half := Vector2(float(fp["hx"]), float(fp["hz"]))
		for snap: Dictionary in all[path]["snaps"]:
			var p := Vector2(float(snap["position"][0]), float(snap["position"][2])) - centre
			var out := Vector2(absf(p.x) - half.x, absf(p.y) - half.y)
			assert_lt(absf(maxf(out.x, out.y)), 1.0, "%s %s: on the edge" % [path.get_file(), snap["name"]])
			var fwd := Vector2(float(snap["forward"][0]), float(snap["forward"][2]))
			assert_gt(fwd.dot(p), 0.0, "%s %s: pointing out of the village" % [path.get_file(), snap["name"]])


func test_a_snap_is_never_spawned() -> void:
	var snap := RoadSnap.new()
	assert_null(PropSync.of(snap), "authoring data only: no PropSync, poi_villages skips it")
	assert_eq(snap.kind_name(), "road")
	snap.kind = RoadSnap.Kind.RAILWAY
	assert_eq(snap.kind_name(), "railway")
	snap.free()
