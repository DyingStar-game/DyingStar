extends GutTest
## FumaroleField: the vents of a field are scattered, not stored — the
## scatter must be deterministic, partitioned per pixel (a parent chunk holds
## exactly the union of its four children's vents, so two LODs never draw a
## vent twice nor lose one), close to the authored density, and the deposit
## stain must stay inside the field.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_fumarole_field.gd

const RADIUS := 6356000.0
var _mpd := RADIUS * PI / 180.0


func _field(lonlat: Vector2, radius_km: float, over: Dictionary = {}) -> FumaroleField.Field:
	return FumaroleField.prepare(FumaroleField.debug_record(lonlat, radius_km, over, _mpd))


func _key(v: Dictionary) -> String:
	var d: Vector3 = v["dir"]
	return "%.9f,%.9f,%.9f" % [d.x, d.y, d.z]


func test_the_scatter_is_deterministic() -> void:
	var c := Vector2(12.3, 24.5)
	var f := _field(c, 1.0, {"density": 40.0, "seed": 5})
	var d := HEALPix.lonlat2vec(c.x, c.y)
	var ns := 4096
	var ip := HEALPix.vec2pix_nest(ns, d)
	var a := FumaroleField.vents_in_chunk([f], ns, ip, RADIUS)
	var b := FumaroleField.vents_in_chunk([f], ns, ip, RADIUS)
	assert_gt(a.size(), 0)
	assert_eq(a.size(), b.size())
	for i in a.size():
		assert_eq(_key(a[i]), _key(b[i]))
		assert_eq(a[i]["r"], b[i]["r"])


func test_a_parent_holds_exactly_the_union_of_its_children() -> void:
	var c := Vector2(12.3, 24.5)
	var f := _field(c, 2.0, {"density": 30.0, "seed": 9})
	var d := HEALPix.lonlat2vec(c.x, c.y)
	var ns := 2048
	var parent := HEALPix.vec2pix_nest(ns, d)
	var p_keys := {}
	for v in FumaroleField.vents_in_chunk([f], ns, parent, RADIUS):
		p_keys[_key(v)] = true
	var c_keys := {}
	for k in 4:
		for v in FumaroleField.vents_in_chunk([f], ns * 2, (parent << 2) | k, RADIUS):
			var key := _key(v)
			assert_false(c_keys.has(key), "a vent in two children")
			c_keys[key] = true
	assert_gt(p_keys.size(), 10)
	assert_eq(c_keys.size(), p_keys.size(), "same count at both levels")
	for key in p_keys:
		assert_true(c_keys.has(key), "parent vent %s missing from the children" % key)


func test_density_is_close_to_the_authored_one() -> void:
	# A field bigger than the chunk: count the vents of a whole n2048 pixel.
	var c := Vector2(12.3, 24.5)
	var f := _field(c, 20.0, {"density": 25.0, "seed": 2})
	var ns := 2048
	var ip := HEALPix.vec2pix_nest(ns, HEALPix.lonlat2vec(c.x, c.y))
	var area_km2 := pow(HEALPix.pixel_side_length(ns, RADIUS) / 1000.0, 2.0)
	var n := FumaroleField.vents_in_chunk([f], ns, ip, RADIUS).size()
	var got := float(n) / area_km2
	assert_between(got, 25.0 * 0.85, 25.0 * 1.15, "%.1f vents/km² for 25 asked" % got)


func test_no_vent_outside_the_field() -> void:
	var c := Vector2(12.3, 24.5)
	var f := _field(c, 0.3, {"density": 200.0})
	var ns := 1024
	var ip := HEALPix.vec2pix_nest(ns, HEALPix.lonlat2vec(c.x, c.y))
	var vents := FumaroleField.vents_in_chunk([f], ns, ip, RADIUS)
	assert_gt(vents.size(), 0)
	for v in vents:
		var ll := HEALPix.vec2lonlat(v["dir"])
		assert_true(MountainRelief._point_in_polygon(ll, f.polygon))


func test_a_hand_placed_vent_belongs_to_its_pixel() -> void:
	var c := Vector2(-40.0, 5.0)
	var v := FumaroleField.prepare({"coverage": "point", "lon": c.x, "lat": c.y, "radius": 3.0,
			"gas": "steam"})
	var ns := 4096
	var home := HEALPix.vec2pix_nest(ns, v.dir)
	assert_eq(FumaroleField.vents_in_chunk([v], ns, home, RADIUS).size(), 1)
	assert_eq(FumaroleField.vents_in_chunk([v], ns, home ^ 1, RADIUS).size(), 0)


func test_the_stain_stays_inside_and_keeps_the_rock() -> void:
	var c := Vector2(12.3, 24.5)
	var f := _field(c, 1.0, {"stain": 1.0, "gas": "sulfur"})
	var rock := Color(0.1, 0.2, 0.6)
	var far := HEALPix.lonlat2vec(c.x + 0.2, c.y)
	assert_eq(FumaroleField.tint(far, rock, [f], RADIUS), rock, "outside: the rock untouched")
	var stained := 0
	for i in 50:
		var ll := c + Vector2(0.0005 * (i % 10), 0.0005 * (i / 10))
		var col := FumaroleField.tint(HEALPix.lonlat2vec(ll.x, ll.y), rock, [f], RADIUS)
		if col != rock:
			stained += 1
			assert_gt(col.r, rock.r, "toward the sulfur yellow")
	assert_gt(stained, 5, "a mottled stain inside")
