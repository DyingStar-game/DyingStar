extends GutTest
## The dust's colour crossing from one biome to the next: each place's dust has its ground's colour
## (DustGround's colour grid), and the colour at the eye glides over time (ColourGlide) instead of
## switching to the next zone's colour in one frame (2026-10-11).

const RED := Color(0.8, 0.2, 0.1)
const BLUE := Color(0.1, 0.2, 0.8)


func test_a_glide_starts_where_it_is_told_then_never_jumps() -> void:
	var glide := ColourGlide.new()
	assert_eq(glide.toward(RED, 0.016), RED, "the first colour is taken at once")
	var next: Color = glide.toward(BLUE, 0.016)
	assert_true(next.b < 0.2 and next.r > 0.7, "one frame later: still almost red")
	for i in 600:
		next = glide.toward(BLUE, 0.016)
	assert_almost_eq(next.b, BLUE.b, 0.01, "ten seconds later: the new biome's colour")


func test_the_grid_keeps_each_places_dust_colour() -> void:
	# The haze over a far range takes that range's colour, not the eye's (2026-10-12): the grid holds the
	# dust's colour of each place, red east of the anchor, blue west.
	var grid := DustGround.new()
	var anchor := Vector3(0.0, 6356000.0, 0.0)
	var f: Array = DustGround.tangent_frame(anchor)
	var east: Vector3 = f[0]
	var flat: Callable = func(_dir: Vector3) -> float: return 6356000.0
	var colour: Callable = func(dir: Vector3, _r: float) -> Color: return RED if (dir * 6356000.0 - anchor).dot(east) > 0.0 else BLUE
	var guard := 0
	while not grid.update(anchor, flat, 1000.0, colour) and guard < DustGround.SIZE + 2:
		guard += 1
	assert_not_null(grid.colour_texture, "a colour grid was laid")
	var img: Image = grid.colour_texture.get_image()
	var mid: int = DustGround.COLOUR_SIZE / 2
	assert_almost_eq(img.get_pixel(DustGround.COLOUR_SIZE - 1, mid).r, RED.r, 0.01, "east: the red ground's dust")
	assert_almost_eq(img.get_pixel(0, mid).b, BLUE.b, 0.01, "west: the blue ground's dust")
