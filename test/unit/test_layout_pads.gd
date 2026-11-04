extends GutTest
## A TerrainPad straight under a layout's root (the mine's yard) levels its own area: LayoutPads reads
## it from the layout and lays it on the village bed's frame, and the footprint covers it.

const RADIUS := 6356000.0
const MPD := RADIUS * PI / 180.0


func _layout_with_pad() -> Node3D:
	var root := Node3D.new()
	var pad := TerrainPad.new()
	pad.name = "Yard"
	pad.position = Vector3(-100.0, 0.0, 0.0)
	var box := CSGBox3D.new()
	box.name = "Ground"
	box.size = Vector3(2.0, 1.0, 4.0)
	box.transform = Transform3D(Basis.from_scale(Vector3(40.0, 1.0, 10.0)), Vector3(20.0, -0.5, -10.0))
	pad.add_child(box)
	root.add_child(pad)
	return root


func test_a_root_pad_is_read_with_its_scaled_box() -> void:
	var root := _layout_with_pad()
	var pads := LayoutPads.of_layout(root)
	assert_eq(pads.size(), 1)
	var box: Transform3D = pads[0]["box"]
	assert_almost_eq(box.origin, Vector3(-80.0, -0.5, -10.0), Vector3.ONE * 0.001, "pad then box offset")
	var fp := LayoutFootprint.of_layout(root)
	assert_false(fp.is_empty(), "the pad alone makes a footprint")
	assert_almost_eq(fp["half"], Vector2(40.0, 20.0) + Vector2.ONE * LayoutFootprint.MARGIN_M, Vector2.ONE * 0.02,
			"80 x 40 m of box, plus the margin")
	root.free()


func test_a_root_pad_lands_on_the_bed_frame() -> void:
	var root := _layout_with_pad()
	var bed := VillageBed.record("village:v", 10.0, 45.0, 0.4, 300.0, 300.0)
	var recs := LayoutPads.to_records(LayoutPads.of_layout(root), bed, Vector2(-80.0, -10.0), MPD)
	assert_eq(recs.size(), 1)
	var rec: Dictionary = recs[0]
	assert_almost_eq(float(rec["lon"]), 10.0, 1e-6, "at the footprint centre: the bed's centre")
	assert_almost_eq(float(rec["lat"]), 45.0, 1e-6)
	assert_almost_eq(float(rec["yaw"]), 0.4, 1e-3, "square with the layout: the bed's heading")
	assert_almost_eq(float(rec["hx"]), 40.0, 0.02, "the box's size times its scale")
	assert_almost_eq(float(rec["hy"]), 20.0, 0.02)
	assert_eq(str(rec["uuid"]), "village:v|pad|Yard")
	root.free()
