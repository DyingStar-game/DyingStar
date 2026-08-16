extends GutTest
## Suite for [SceneScatter] — the editor tool that scatters scene instances inside a zone.
##
## Two of the three layers are exercised here: point sampling / weighted item picking (pure),
## and [method SceneScatter.build_instances] (which takes its owner as a parameter precisely so a
## harness can drive it without an editor). Ground projection is left out: it needs a live physics
## step, since direct_space_state is only valid inside _physics_process.
##
## Four properties matter and are asserted:
##
##   · sampling is DETERMINISTIC — the same seed always rebuilds the same layout, which is what
##     makes the "Generate" button safe to press twice and what lets a designer reproduce a
##     layout after a revert;
##   · every returned point is really INSIDE the zone, for each supported shape, and the test
##     is analytic (no physics query), matching how the tool itself decides containment;
##   · min_spacing is honoured through the hash grid, and the loop always terminates even when
##     the zone is far too small to fit `count` points;
##   · the generated instances are actually SERIALISED — the whole point of the tool. They are
##     packed back into a PackedScene here, which is exactly what the editor does on save, so a
##     missing owner assignment fails the suite instead of silently losing the layout.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_scene_scatter.gd

const SEED := 12345
## Slack on the float comparisons against a shape boundary.
const EPS := 0.001

var _scatter: SceneScatter
var _zone: Area3D
var _shape_node: CollisionShape3D


func before_each() -> void:
	_scatter = SceneScatter.new()
	_scatter.name = "SceneScatter"
	_zone = Area3D.new()
	_zone.name = "Zone"
	_shape_node = CollisionShape3D.new()
	_zone.add_child(_shape_node)
	_scatter.add_child(_zone)
	# sample_points() reads global transforms, so the node has to live in a tree.
	add_child_autofree(_scatter)


# ── Fixtures ───────────────────────────────────────────────────────────

func _use_box(size: Vector3) -> void:
	var box := BoxShape3D.new()
	box.size = size
	_shape_node.shape = box


func _use_sphere(radius: float) -> void:
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	_shape_node.shape = sphere


func _use_cylinder(radius: float, height: float) -> void:
	var cyl := CylinderShape3D.new()
	cyl.radius = radius
	cyl.height = height
	_shape_node.shape = cyl


func _item(weight: float, scene: PackedScene = null) -> ScatterItemDef:
	var item := ScatterItemDef.new()
	item.weight = weight
	# is_usable() requires a scene; any PackedScene will do, the tests never instance it.
	item.scene = scene if scene != null else _dummy_scene()
	return item


func _dummy_scene() -> PackedScene:
	var packed := PackedScene.new()
	var node := Node3D.new()
	packed.pack(node)
	node.free()
	return packed


func _sample(seed_value: int = SEED) -> Array[Vector3]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return _scatter.sample_points(rng)


# ── Determinism ────────────────────────────────────────────────────────

func test_sampling_is_deterministic_for_the_same_seed() -> void:
	_use_box(Vector3(100.0, 20.0, 100.0))
	_scatter.count = 40
	_scatter.min_spacing = 2.0
	var first := _sample()
	var second := _sample()
	assert_eq(first.size(), second.size(), "same seed should place the same number of points")
	for i in first.size():
		assert_eq(first[i], second[i], "point %d should be identical across runs" % i)


func test_a_different_seed_gives_a_different_layout() -> void:
	_use_box(Vector3(100.0, 20.0, 100.0))
	_scatter.count = 40
	var first := _sample(SEED)
	var second := _sample(SEED + 1)
	assert_gt(first.size(), 0, "the box zone should yield points")
	assert_ne(first[0], second[0], "a different seed should move the first point")


func test_effective_seed_falls_back_to_a_stable_node_hash() -> void:
	_scatter.random_seed = 0
	var derived := _scatter.effective_seed()
	assert_ne(derived, 0, "seed 0 should be resolved to a derived value")
	assert_eq(derived, _scatter.effective_seed(), "the derived seed must be stable across calls")
	_scatter.random_seed = 999
	assert_eq(_scatter.effective_seed(), 999, "an explicit seed must win")


# ── Containment ────────────────────────────────────────────────────────

func test_all_points_are_inside_the_box_shape() -> void:
	_use_box(Vector3(40.0, 10.0, 60.0))
	_scatter.count = 60
	_scatter.min_spacing = 0.0
	_scatter.volume_3d = true
	var points := _sample()
	assert_eq(points.size(), 60, "an empty-spacing box should always reach the requested count")
	for p in points:
		assert_between(p.x, -20.0, 20.0, "x inside the box")
		assert_between(p.y, -5.0, 5.0, "y inside the box")
		assert_between(p.z, -30.0, 30.0, "z inside the box")


func test_all_points_are_inside_the_sphere_shape() -> void:
	_use_sphere(25.0)
	_scatter.count = 60
	_scatter.min_spacing = 0.0
	_scatter.volume_3d = true
	var points := _sample()
	assert_gt(points.size(), 0, "the sphere zone should yield points")
	for p in points:
		assert_lte(p.length(), 25.0 + EPS, "point should sit within the sphere radius")


func test_all_points_are_inside_the_cylinder_shape() -> void:
	_use_cylinder(15.0, 8.0)
	_scatter.count = 60
	_scatter.min_spacing = 0.0
	_scatter.volume_3d = true
	var points := _sample()
	assert_gt(points.size(), 0, "the cylinder zone should yield points")
	for p in points:
		assert_lte(Vector2(p.x, p.z).length(), 15.0 + EPS, "point within the cylinder radius")
		assert_between(p.y, -4.0, 4.0, "point within the cylinder height")


func test_surface_mode_flattens_points_onto_the_zone_plane() -> void:
	_use_box(Vector3(40.0, 30.0, 40.0))
	_zone.position = Vector3(0.0, 7.0, 0.0)
	_scatter.count = 30
	_scatter.min_spacing = 0.0
	_scatter.volume_3d = false
	for p in _sample():
		assert_almost_eq(p.y, 7.0, 0.001, "surface mode should flatten onto the zone origin plane")


func test_zone_offset_moves_the_sampled_points() -> void:
	_use_box(Vector3(10.0, 10.0, 10.0))
	_shape_node.position = Vector3(100.0, 0.0, 0.0)
	_scatter.count = 20
	_scatter.min_spacing = 0.0
	_scatter.volume_3d = true
	for p in _sample():
		assert_between(p.x, 95.0, 105.0, "points should follow the shape node's own offset")


func test_no_points_without_a_usable_shape() -> void:
	_shape_node.shape = null
	_scatter.count = 20
	assert_eq(_sample().size(), 0, "a zone with no shape should place nothing")


# ── Spacing ────────────────────────────────────────────────────────────

func test_points_respect_min_spacing() -> void:
	_use_box(Vector3(100.0, 4.0, 100.0))
	_scatter.count = 50
	_scatter.min_spacing = 6.0
	var points := _sample()
	assert_gt(points.size(), 1, "the zone should fit several spaced points")
	for i in points.size():
		for j in range(i + 1, points.size()):
			assert_gte(points[i].distance_to(points[j]), 6.0 - EPS,
					"points %d and %d should be at least min_spacing apart" % [i, j])


func test_count_is_capped_when_the_zone_is_too_small() -> void:
	# A 5 m box cannot hold 200 points 4 m apart: the loop must give up, not hang.
	_use_box(Vector3(5.0, 5.0, 5.0))
	_scatter.count = 200
	_scatter.min_spacing = 4.0
	var points := _sample()
	assert_lt(points.size(), 200, "an oversubscribed zone should place fewer points than asked")
	assert_gt(points.size(), 0, "it should still place what fits")


# ── Weighted item picking ──────────────────────────────────────────────

func test_weighted_pick_follows_weights() -> void:
	var common := _item(0.9)
	var rare := _item(0.1)
	var mix: Array[ScatterItemDef] = [common, rare]
	_scatter.items = mix
	var pool := _scatter.resolve_items()
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var common_hits := 0
	for i in 1000:
		if _scatter.pick_item(rng, pool) == common:
			common_hits += 1
	assert_between(common_hits, 850, 950, "a 0.9/0.1 mix should pick the common item ~90% of the time")


func test_zero_weight_item_is_never_picked() -> void:
	var never := _item(0.0)
	var always := _item(1.0)
	var mix: Array[ScatterItemDef] = [never, always]
	_scatter.items = mix
	var pool := _scatter.resolve_items()
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	for i in 200:
		assert_eq(_scatter.pick_item(rng, pool), always, "a weight of 0 must never be picked")


func test_item_without_a_scene_is_never_picked() -> void:
	var no_scene := ScatterItemDef.new()
	no_scene.weight = 10.0
	var usable := _item(1.0)
	var mix: Array[ScatterItemDef] = [no_scene, usable]
	_scatter.items = mix
	var pool := _scatter.resolve_items()
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	for i in 200:
		assert_eq(_scatter.pick_item(rng, pool), usable, "an item without a scene must never be picked")


func test_pick_item_returns_null_when_nothing_is_usable() -> void:
	var mix: Array[ScatterItemDef] = [_item(0.0)]
	_scatter.items = mix
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	assert_null(_scatter.pick_item(rng, _scatter.resolve_items()), "an unusable mix should yield null, not a crash")


# ── The two inspector paths ("scenes" shortcut vs "items") ─────────────

func test_a_plain_scene_is_scattered_with_default_settings() -> void:
	var packed := _dummy_scene()
	var list: Array[PackedScene] = [packed]
	_scatter.scenes = list
	var pool := _scatter.resolve_items()
	assert_eq(pool.size(), 1, "a scene dropped into \"scenes\" should produce one mix entry")
	assert_eq(pool[0].scene, packed, "the entry should point at the dropped scene")
	assert_eq(pool[0].weight, 1.0, "a plain scene should get the default weight")
	assert_true(pool[0].random_yaw, "a plain scene should get the default variations")


func test_scenes_and_items_are_mixed_not_replaced() -> void:
	var list: Array[PackedScene] = [_dummy_scene(), _dummy_scene()]
	_scatter.scenes = list
	var mix: Array[ScatterItemDef] = [_item(1.0)]
	_scatter.items = mix
	assert_eq(_scatter.resolve_items().size(), 3, "both inspector paths should feed the same mix")


func test_empty_entries_are_skipped() -> void:
	var list: Array[PackedScene] = [null]
	_scatter.scenes = list
	var mix: Array[ScatterItemDef] = [null]
	_scatter.items = mix
	assert_eq(_scatter.resolve_items().size(), 0, "empty inspector slots must not reach the mix")


# ── Item variations ────────────────────────────────────────────────────

func test_pick_scale_stays_within_the_range() -> void:
	var item := _item(1.0)
	item.scale_min = 0.5
	item.scale_max = 2.0
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	for i in 200:
		assert_between(item.pick_scale(rng), 0.5, 2.0, "scale should stay inside the configured range")


func test_pick_scale_tolerates_a_reversed_range() -> void:
	var item := _item(1.0)
	item.scale_min = 3.0
	item.scale_max = 1.0
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	for i in 50:
		assert_between(item.pick_scale(rng), 1.0, 3.0, "a reversed min/max should still produce a sane scale")


# ── Instantiation & serialisation ──────────────────────────────────────

## Three placements of one item, at 10 m intervals along X.
func _placements(item: ScatterItemDef, n: int = 3) -> Array[Dictionary]:
	var placements: Array[Dictionary] = []
	for i in n:
		placements.append({"item": item, "transform": Transform3D(Basis(), Vector3(i * 10.0, 0.0, 0.0))})
	return placements


func test_build_instances_creates_the_generated_container() -> void:
	var created := _scatter.build_instances(_placements(_item(1.0)), _scatter)
	assert_eq(created, 3, "every placement should produce an instance")
	var container := _scatter.get_node_or_null(SceneScatter.GENERATED_ROOT)
	assert_not_null(container, "a \"Generated\" container should have been created")
	assert_true(container.get_meta(SceneScatter.GENERATED_META, false), "the container should carry its marker meta")
	assert_eq(container.get_child_count(), 3, "the container should hold one node per placement")


func test_build_instances_applies_the_placement_transform() -> void:
	_scatter.build_instances(_placements(_item(1.0)), _scatter)
	var container := _scatter.get_node(SceneScatter.GENERATED_ROOT)
	for i in 3:
		assert_eq((container.get_child(i) as Node3D).position, Vector3(i * 10.0, 0.0, 0.0),
				"instance %d should sit at its placement position" % i)


func test_build_instances_replaces_the_previous_output() -> void:
	_scatter.build_instances(_placements(_item(1.0), 5), _scatter)
	_scatter.build_instances(_placements(_item(1.0), 2), _scatter)
	var containers := 0
	for child in _scatter.get_children():
		if child.name == SceneScatter.GENERATED_ROOT:
			containers += 1
	assert_eq(containers, 1, "regenerating must replace the container, never add a second one")
	assert_eq(_scatter.get_node(SceneScatter.GENERATED_ROOT).get_child_count(), 2,
			"only the newest layout should remain")


func test_generated_instances_are_owned_and_serialised() -> void:
	# This is the property the whole tool exists for: pack the tree the way the editor does on
	# save and check the instances survive the round-trip.
	var root := Node3D.new()
	add_child_autofree(root)
	var scatter := SceneScatter.new()
	scatter.name = "SceneScatter"
	root.add_child(scatter)
	scatter.owner = root

	var created := scatter.build_instances(_placements(_item(1.0), 4), root)
	assert_eq(created, 4, "four instances should be created")
	for child in scatter.get_node(SceneScatter.GENERATED_ROOT).get_children():
		assert_eq(child.owner, root, "each instance must be owned by the scene root to be saved")

	var packed := PackedScene.new()
	assert_eq(packed.pack(root), OK, "the tree should pack without error")
	var reloaded := packed.instantiate()
	autofree(reloaded)
	var container := reloaded.get_node_or_null("SceneScatter/%s" % SceneScatter.GENERATED_ROOT)
	assert_not_null(container, "the \"Generated\" container should survive the save/reload")
	assert_eq(container.get_child_count(), 4, "every instance should survive the save/reload")


func test_unowned_instances_are_not_serialised() -> void:
	# The negative control for the test above: no owner means the editor writes nothing.
	var root := Node3D.new()
	add_child_autofree(root)
	var scatter := SceneScatter.new()
	scatter.name = "SceneScatter"
	root.add_child(scatter)
	scatter.owner = root

	scatter.build_instances(_placements(_item(1.0), 4), null)
	var packed := PackedScene.new()
	assert_eq(packed.pack(root), OK, "the tree should pack without error")
	var reloaded := packed.instantiate()
	autofree(reloaded)
	assert_null(reloaded.get_node_or_null("SceneScatter/%s" % SceneScatter.GENERATED_ROOT),
			"unowned output must not be written into the packed scene")


# ── Planet ground source ───────────────────────────────────────────────

## Stand-in for PlanetTerrain: exposes the two members SceneScatter duck-types on, and a
## heightmap that is a plain tilted plane so the expected normal is known analytically.
class StubPlanet:
	extends Node3D

	const RADIUS := 1000.0
	## Height gain per metre travelled along +X — a 100% grade, i.e. a 45° slope.
	var slope := 0.0
	## Only its null-ness matters to SceneScatter; Variant so a test can clear it.
	var planet_data: Variant = "not-null"

	func surface_point_for_direction(dir: Vector3) -> Vector3:
		var d := dir.normalized()
		return d * (RADIUS + d.x * RADIUS * slope)


func _planet_scatter(slope: float) -> Array:
	var root := Node3D.new()
	add_child_autofree(root)
	var stub := StubPlanet.new()
	stub.name = "StubPlanet"
	stub.slope = slope
	root.add_child(stub)
	var scatter := SceneScatter.new()
	scatter.name = "SceneScatter"
	# Just above the north pole of the stub, so the zone straddles the surface.
	scatter.position = Vector3(0.0, StubPlanet.RADIUS, 0.0)
	root.add_child(scatter)
	scatter.owner = root
	var zone := Area3D.new()
	zone.name = "Zone"
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, 20.0, 40.0)
	cs.shape = box
	zone.add_child(cs)
	scatter.add_child(zone)
	var list: Array[PackedScene] = [_dummy_scene()]
	scatter.scenes = list
	scatter.count = 10
	scatter.min_spacing = 1.0
	scatter.random_seed = SEED
	return [scatter, stub]


func test_a_sibling_planet_is_auto_detected() -> void:
	var built := _planet_scatter(0.0)
	assert_eq(built[0]._resolve_planet(), built[1], "the planet should be found even as a sibling branch")


func test_a_planet_without_data_is_ignored() -> void:
	var built := _planet_scatter(0.0)
	built[1].planet_data = null
	assert_null(built[0]._resolve_planet(), "a planet with no heightmap data must not be used")


func test_points_land_on_the_planet_surface() -> void:
	# The regression this whole path exists for: planet terrain has no collider in the editor,
	# so a raycast places nothing. Every sampled point must still reach the heightmap surface.
	var built := _planet_scatter(0.0)
	var scatter: SceneScatter = built[0]
	var stub: Node3D = built[1]
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var points := scatter.sample_points(rng)
	assert_gt(points.size(), 0, "the zone should yield points")
	var landed := scatter._project_to_ground(points)
	assert_eq(landed.size(), points.size(), "a flat planet should accept every sampled point")
	for hit in landed:
		var radius: float = (stub.to_local(hit["position"] as Vector3)).length()
		assert_almost_eq(radius, StubPlanet.RADIUS, 0.001, "the instance should sit on the surface radius")


func test_a_slope_steeper_than_the_limit_is_rejected() -> void:
	# A 45.0deg plane against a 30.0deg limit: nothing may be placed.
	var built := _planet_scatter(1.0)
	var scatter: SceneScatter = built[0]
	scatter.max_slope_deg = 30.0
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	assert_eq(scatter._project_to_ground(scatter.sample_points(rng)).size(), 0,
			"ground steeper than max_slope_deg must be rejected")
	# ...and the same ground passes once the limit allows it.
	scatter.max_slope_deg = 60.0
	rng.seed = SEED
	assert_gt(scatter._project_to_ground(scatter.sample_points(rng)).size(), 0,
			"the same ground should pass under a higher limit")


func test_clear_generated_removes_everything() -> void:
	_scatter.build_instances(_placements(_item(1.0)), _scatter)
	_scatter.clear_generated()
	assert_null(_scatter.get_node_or_null(SceneScatter.GENERATED_ROOT), "clearing should drop the container")
