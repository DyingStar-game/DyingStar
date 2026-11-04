extends GutTest
## RockImpurityNative (RockImpurity.tint_chunk) against the GDScript it replaces on a chunk, BIT FOR BIT.
##
## The colours are baked into the chunk meshes cached on disk: a twin off by one bit would make a chunk
## depend on which path built it. So on Linux, where both call glibc's sin, nothing here is "close enough".
## Elsewhere the engine's own sin differs a little (see test_tile_frame_native.gd) and the bound is what a
## colour can show.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_rock_impurity_native.gd -gexit

const RADIUS := 3467000.0
## A colour component, far under the 1/255 a screen shows: bound off Linux.
const CROSS_MACHINE_COLOR := 1.0e-4
const N := 400

var _dirs := PackedVector3Array()
var _normals := PackedVector3Array()
var _heights := PackedFloat32Array()
var _core := PackedFloat32Array()
var _carve := PackedFloat32Array()
var _wall := PackedFloat32Array()
var _colors := PackedColorArray()


func before_all() -> void:
	RockCatalogue.reload()
	RockImpurity.reset()
	RockImpurity.warm()
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	for i: int in N:
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
		_dirs.append(d)
		# From flat to a vertical wall: the dust's slope band and past it.
		_normals.append((d + Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
				* rng.randf_range(0.0, 1.5)).normalized())
		_heights.append(rng.randf_range(-400.0, 6000.0))
		# The plain, the dust's band, a crest, and past the 1.5 an element field clamps at.
		_core.append([0.0, 0.2, 1.0, 1.8][i % 4])
		_carve.append([0.0, 40.0, 150.0, 400.0][(i / 4) % 4])
		# No network, in the crack, on the wall, in the vein halo, past it.
		_wall.append([INF, -30.0, 0.0, 17.0, 90.0][i % 5])
		_colors.append(Color(rng.randf(), rng.randf(), rng.randf()))


func after_each() -> void:
	RockImpurity.use_native = true


func _slots(value: int) -> PackedByteArray:
	var slots := PackedByteArray()
	slots.resize(N)
	slots.fill(value)
	return slots


func _reference(slug: String, i: int) -> Color:
	return RockImpurity.tint(slug, _dirs[i], RADIUS, _heights[i], _core[i], _carve[i],
			1.0 - _normals[i].dot(_dirs[i]), _colors[i], _wall[i])


func _assert_same(got: Color, want: Color, label: String) -> bool:
	if OS.get_name() == "Linux":
		if got != want:
			assert_eq(got, want, label)
			return false
		return true
	var worst := maxf(maxf(absf(got.r - want.r), absf(got.g - want.g)),
			maxf(absf(got.b - want.b), absf(got.a - want.a)))
	if worst > CROSS_MACHINE_COLOR:
		assert_lte(worst, CROSS_MACHINE_COLOR, label)
		return false
	return true


func test_the_assembly_is_there() -> void:
	assert_false(RockImpurity.tint_chunk(["corundum_red"], _slots(1), _dirs, _normals, RADIUS, _heights, _core,
			_carve, _colors, _wall).is_empty(), "RockImpurityNative.cs must answer, or this file tests nothing")


## Every rock of the catalogue, so every rule: pure, the Fe + Ti pair, the weighted mean, with and without
## core colours, with no colours at all.
func test_every_rock_tints_identically() -> void:
	var rules_seen := {}
	for slug: String in RockCatalogue.slugs():
		var rule := RockImpurity.rule_of(slug)
		rules_seen["pure" if (rule["elements"] as PackedStringArray).is_empty()
				else ("pair" if rule["pair"] else "mean")] = true
		var slugs: Array[String] = [slug]
		var got := RockImpurity.tint_chunk(slugs, _slots(1), _dirs, _normals, RADIUS, _heights, _core, _carve,
				_colors, _wall)
		assert_eq(got.size(), N, slug)
		for i: int in N:
			if not _assert_same(got[i], _reference(slug, i), "%s, sample %d" % [slug, i]):
				return
	assert_eq(rules_seen.size(), 3, "the catalogue exercises the three rules: %s" % str(rules_seen.keys()))


## Not a vacuous equality: the inputs do move the colour, by every route the rule has.
func test_the_samples_reach_every_term() -> void:
	var red: Array[String] = ["corundum_red"]
	var got := RockImpurity.tint_chunk(red, _slots(1), _dirs, _normals, RADIUS, _heights, _core, _carve,
			_colors, _wall)
	var distinct := {}
	for c: Color in got:
		distinct[c] = true
	assert_gt(distinct.size(), N / 2, "a colour of its own for most samples")
	var dusted := 0
	for i: int in N:
		if RockImpurity.dust_weight(_core[i], 1.0 - _normals[i].dot(_dirs[i])) > 0.0:
			dusted += 1
	assert_gt(dusted, 10, "the dust term is reached")


func test_a_vertex_without_rock_keeps_its_colour() -> void:
	var slots := _slots(0)
	for i: int in range(0, N, 2):
		slots[i] = 1 + (i / 2) % 2
	var two: Array[String] = ["corundum_blue", "corundum_green"]
	var got := RockImpurity.tint_chunk(two, slots, _dirs, _normals, RADIUS, _heights, _core, _carve, _colors, _wall)
	for i: int in N:
		if slots[i] == 0:
			assert_eq(got[i], _colors[i], "slot 0 keeps its colour")
		elif not _assert_same(got[i], _reference(two[slots[i] - 1], i), "slot %d, sample %d" % [slots[i], i]):
			return


func test_it_declines_what_it_cannot_answer() -> void:
	var unknown: Array[String] = ["nonexistent"]
	assert_true(RockImpurity.tint_chunk(unknown, _slots(1), _dirs, _normals, RADIUS, _heights, _core, _carve,
			_colors, _wall).is_empty(), "a rock out of the catalogue goes back to tint(), which returns the fallback")
	RockImpurity.use_native = false
	var red: Array[String] = ["corundum_red"]
	assert_true(RockImpurity.tint_chunk(red, _slots(1), _dirs, _normals, RADIUS, _heights, _core, _carve,
			_colors, _wall).is_empty(), "the switch of the tests")
