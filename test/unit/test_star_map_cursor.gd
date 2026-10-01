extends GutTest
## Where on the ground the cursor points: the chart knew which body, never where on it.

const BODY: String = "tarsis_3"


## No relief to read ("no_such_body" has no data: its ground is the reference sphere): the ray meets
## the sphere where geometry says, and the direction is given in the body's own frame.
func test_a_ray_meets_a_bare_sphere_where_geometry_says() -> void:
	var turned := Basis(Vector3.UP, 0.7)
	var local: Vector3 = StarMapRelief.surface_hit(Vector3(0, 0, 10), Vector3(0, 0, -1), Vector3.ZERO,
			2.0, turned, "no_such_body")
	assert_almost_eq((turned * local).distance_to(Vector3(0, 0, 1)), 0.0, 1.0e-6,
		"the near side, facing the eye, in the body's frame")


func test_a_ray_past_the_limb_meets_nothing() -> void:
	assert_eq(StarMapRelief.surface_hit(Vector3(0, 5, 10), Vector3(0, 0, -1), Vector3.ZERO, 2.0,
			Basis.IDENTITY, "no_such_body"), Vector3.ZERO)
	assert_eq(StarMapRelief.surface_hit(Vector3(0, 0, 10), Vector3(0, 0, 1), Vector3.ZERO, 2.0,
			Basis.IDENTITY, "no_such_body"), Vector3.ZERO, "a body behind the eye is not under the cursor")


## Over a real relief, a ray aimed at a town comes back on that town: the point is on the GROUND, not
## on the reference sphere, which a ray seen at an angle meets kilometres away.
func test_aimed_at_a_town_the_cursor_reads_that_town() -> void:
	if not StarMapRelief.has_data(BODY):
		pending("pas de tuiles %s sur cette machine" % BODY)
		return
	var radius: float = 0.5
	var town: Dictionary = StarMapPoi.load_for(BODY)[0]
	var dir: Vector3 = town["dir"]
	var ground: Vector3 = dir * radius * StarMapRelief.surface_factor(BODY, dir)
	# From high up and to one side, so the reference sphere and the ground part company.
	var eye: Vector3 = ground + (dir + dir.cross(Vector3.UP).normalized() * 0.8).normalized() * 0.02
	var local: Vector3 = StarMapRelief.surface_hit(eye, (ground - eye).normalized(), Vector3.ZERO, radius,
			Basis.IDENTITY, BODY, 4)
	var off_m: float = local.angle_to(dir) * 6356000.0
	assert_lt(off_m, 200.0, "%s: within 200 m of the town (%.0f m)" % [town["label"], off_m])


func test_the_readout_gives_as_many_decimals_as_a_pixel_resolves() -> void:
	var text: String = StarMap.cursor_text("no_such_body", HEALPix.lonlat2vec(12.5, -3.25), 100.0, 6356000.0)
	assert_string_contains(text, "12.5000", "a hundred metres a pixel, a thousandth of a degree: four decimals")
	assert_string_contains(text, "-3.2500")
	assert_false(text.contains(" m"), "no relief, no height")


func test_the_readout_stays_on_screen() -> void:
	var span := Vector2(200, 20)
	var at: Vector2 = StarMapCursorReadout.place(Vector2(1900, 1070), span, Vector2(1920, 1080))
	assert_lt(at.x + span.x, 1920.1, "pushed left of the cursor near the right edge")
	assert_lt(at.y, 1080.1, "and above it near the bottom")
