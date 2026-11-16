extends GutTest
## HumanMorphNative.cs (the C# loops of a body bake) against human_morph.gd, the GDScript it stands in
## for: morphing the basemesh, fitting a worn asset, the render surface, the triangles left visible.
##
## Sums run in doubles on both sides, rounded to float32 at the end: equal to a few ulps.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_human_morph_native.gd -gexit

const EPS := 2e-6

var _native: HumanMorph
var _gd: HumanMorph


func before_all() -> void:
	var bank := load(HumanBank.PATH) as HumanBank
	_native = HumanMorph.new(bank, HumanMorph.native_instance())
	_gd = HumanMorph.new(bank, null)


func _order(seed_value: int) -> HumanBuilder.Order:
	HumanBuilder.prepare()
	return HumanBuilder.order_for(CharacterAppearance.random(seed_value))


func _same_points(a: PackedVector3Array, b: PackedVector3Array, what: String) -> void:
	assert_eq(a.size(), b.size(), what + ": same size")
	var worst: float = 0.0
	for i in mini(a.size(), b.size()):
		worst = maxf(worst, a[i].distance_to(b[i]))
	assert_lt(worst, EPS, "%s: C# and GDScript agree (worst %s m)" % [what, String.num_scientific(worst)])


func test_native_is_available() -> void:
	assert_true(_native.is_native(), "HumanMorphNative.cs must load, or this file tests nothing (rebuild the C#)")


func test_morph_matches() -> void:
	var order: HumanBuilder.Order = _order(7)
	assert_gt(order.targets.size(), 10, "a random look moves many targets")
	_same_points(_native.morph(order.targets, order.weights), _gd.morph_gd(order.targets, order.weights), "morph")


func test_fit_matches() -> void:
	var order: HumanBuilder.Order = _order(11)
	var body: PackedVector3Array = _native.morph(order.targets, order.weights)
	for asset in order.assets:
		_same_points(_native.fit(body, asset), _gd.fit_gd(body, asset.refs, asset.weights, asset.offsets,
				asset.scale_pairs, asset.scale_ref), "fit %s" % asset.id)


func test_surface_and_visible_triangles_match() -> void:
	var order: HumanBuilder.Order = _order(3)
	var bank: HumanBank = _native.bank
	var body: PackedVector3Array = _native.morph(order.targets, order.weights)
	var shift := Vector3(0.0, 0.9, 0.0)
	var index: PackedInt32Array = HumanBuilder._body_index
	var a: Array = _native.surface(body, bank.body_vertex, index, bank.body_tangent, shift)
	var b: Array = _gd.surface_gd(body, bank.body_vertex, index, bank.body_tangent, shift)
	_same_points(a[0], b[0], "positions")
	_same_points(a[1], b[1], "normals")
	var ta: PackedFloat32Array = a[2]
	var tb: PackedFloat32Array = b[2]
	var worst: float = 0.0
	for i in ta.size():
		worst = maxf(worst, absf(ta[i] - tb[i]))
	assert_lt(worst, 1e-5, "tangents agree (worst %s)" % String.num_scientific(worst))
	var hidden := PackedByteArray()
	hidden.resize(body.size())
	for asset in order.assets:
		for v in asset.delete:
			hidden[v] = 1
	assert_eq(_native.visible_triangles(index, bank.body_vertex, hidden),
			_gd.visible_triangles_gd(index, bank.body_vertex, hidden), "same visible triangles")


func test_face_unit_and_picked_surface_match() -> void:
	var order: HumanBuilder.Order = _order(9)
	var bank: HumanBank = _native.bank
	var body: PackedVector3Array = _native.morph(order.targets, order.weights)
	var unit: int = bank.target_index(bank.face_units[0])
	assert_ne(unit, -1, "the bank has its face units")
	var moved: PackedVector3Array = _native.with_target(body, unit, 0.8)
	_same_points(moved, _gd.with_target_gd(body, unit, 0.8), "with_target")
	var picks := PackedInt32Array([0, 5, 77, 1000, bank.body_vertex.size() - 1])
	var a: Array = _native.surface_picked(moved, bank.body_vertex, HumanBuilder._body_index, bank.body_tangent, Vector3.ZERO, picks)
	var b: Array = _gd.surface_picked_gd(moved, bank.body_vertex, HumanBuilder._body_index, bank.body_tangent, Vector3.ZERO, picks)
	_same_points(a[0], b[0], "picked positions")
	_same_points(a[1], b[1], "picked normals")
