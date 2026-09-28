extends GutTest
## A station ring turns at the rate its floor's gravity demands (ω = √(g / r)), read off its own rim, and as a
## pure function of the shared clock — so every machine draws it at the same angle.

const RIM_RADIUS := 98.8682  # the test station's rims


func _ring(rim: float = RIM_RADIUS) -> SpinGravityRing:
	var ring: SpinGravityRing = autofree(SpinGravityRing.new())
	var tyre := CSGCylinder3D.new()
	tyre.radius = rim
	ring.add_child(tyre)
	var hole := CSGCylinder3D.new()  # the rim's hollow: cut away, never the floor
	hole.radius = rim * 1.5
	hole.operation = CSGShape3D.OPERATION_SUBTRACTION
	tyre.add_child(hole)
	var spoke := CSGCylinder3D.new()
	spoke.radius = 6.2
	ring.add_child(spoke)
	return ring


func test_one_g_on_the_test_station_is_a_turn_every_twenty_seconds() -> void:
	var ring: SpinGravityRing = _ring()
	# A CSGCylinder3D keeps its radius in SINGLE precision (98.8682 reads back 98.86820221): tolerances to match.
	assert_almost_eq(ring.angular_rate(), sqrt(9.80665 / RIM_RADIUS), 1.0e-7)
	assert_almost_eq(TAU / ring.angular_rate(), 19.95, 0.05, "3 rpm")


func test_the_floor_is_the_rim_not_a_spoke_nor_the_hollow() -> void:
	assert_almost_eq(_ring().floor_radius(), RIM_RADIUS, 1.0e-4)


func test_a_radius_set_by_hand_wins() -> void:
	var ring: SpinGravityRing = _ring()
	ring.floor_radius_m = 50.0
	assert_almost_eq(ring.floor_radius(), 50.0, 1.0e-9)
	assert_almost_eq(ring.angular_rate(), sqrt(9.80665 / 50.0), 1.0e-9)


func test_the_angle_is_a_function_of_the_clock_alone() -> void:
	var ring: SpinGravityRing = _ring()
	var period: float = TAU / ring.angular_rate()
	var t: float = 1790540000.0  # a real clock reading: large, and still exact in double precision
	assert_almost_eq(ring.angle_at(t), ring.angle_at(t + period), 1.0e-5, "the same after one full turn")
	assert_almost_eq(ring.angle_at(t + period * 0.25), fposmod(ring.angle_at(t) + PI * 0.5, TAU), 1.0e-5)


func test_no_rim_no_turn() -> void:
	var bare: SpinGravityRing = autofree(SpinGravityRing.new())
	assert_eq(bare.angular_rate(), 0.0)
