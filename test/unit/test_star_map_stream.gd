extends GutTest

## What the chart asks the tile service for.
##
## Only the RULE is exercised here, never the asking: opening a service talks to the network to find the
## current version, which is not a thing a unit test should do. The rule is the whole of what could be
## wrong — never ask twice, never ask for too much at once — and it is a pure function of the wanted set.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_star_map_stream.gd


func _tiles(nside: int, count: int) -> Dictionary:
	var out: Dictionary = {}
	for ipix: int in range(count):
		out[StarMapGround.tile_id(nside, ipix)] = true
	return out


## A pass asks for a couple of dozen at most, however much is wanted.
##
## The queue is served one tile at a time over HTTP, so handing it a whole patch would take minutes to
## drain and the tiles under the eye would sit behind tiles off the edge of the screen.
func test_one_pass_asks_for_a_bounded_number() -> void:
	var stream := StarMapStream.new()
	var picked: Array[int] = stream._pick(_tiles(64, 300))
	assert_eq(picked.size(), StarMapStream.MAX_PER_PASS, "bounded, whatever is wanted")


## And what a pass did not get to is picked up by the next, the wanted set being recomputed each time.
func test_what_is_left_over_is_asked_for_next_time() -> void:
	var stream := StarMapStream.new()
	var wanted: Dictionary = _tiles(64, 60)
	var seen: Dictionary = {}
	for pass_number: int in range(4):
		for id: int in stream._pick(wanted):
			assert_false(seen.has(id), "no tile is ever asked for twice")
			seen[id] = true
	assert_eq(seen.size(), 60, "and in the end the whole set has been asked for")


## Nothing is asked for twice even when the view slides and the same tiles come back round.
func test_a_tile_is_never_asked_for_twice() -> void:
	var stream := StarMapStream.new()
	var first: Array[int] = stream._pick(_tiles(64, 10))
	assert_eq(first.size(), 10, "sanity: all ten were new")
	assert_eq(stream._pick(_tiles(64, 10)).size(), 0, "the same ten, asked for nothing")


## Letting the body go forgets what was asked for, because the next body's tiles are different tiles.
func test_changing_body_starts_over() -> void:
	var stream := StarMapStream.new()
	stream._pick(_tiles(64, 5))
	stream.close()
	assert_eq(stream._pick(_tiles(64, 5)).size(), 5, "a fresh body asks afresh")


## And no body at all asks for nothing, rather than reaching for a service.
func test_no_body_asks_for_nothing() -> void:
	var stream := StarMapStream.new()
	stream.want("", _tiles(64, 10))
	assert_eq(stream._asked.size(), 0, "nothing to ask, and nothing to open")
