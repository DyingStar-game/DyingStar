extends GutTest
## The character bank (assets/_universe/characters/human/human_bank.res) is complete and coherent.
##
## The bank is generated (tools/character/human_bank) and every later stage trusts its layout: the
## runtime builder indexes deltas, joints and assets by position, and saved appearances store slider
## and asset ids. These checks catch a bank packed from a mismatched npz, a catalogue entry whose target
## was dropped, an asset choice with no mesh, or a skeleton the game's animations cannot drive.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_human_bank.gd -gexit

const BANK_PATH := "res://assets/_universe/characters/human/human_bank.res"
const CHARACTER_SCENE := "res://assets/_universe/characters/humanoids/man_ddurieux.glb"

var _bank: HumanBank


func before_all() -> void:
	_bank = load(BANK_PATH) as HumanBank


func test_the_bank_loads() -> void:
	assert_not_null(_bank, "the bank must load as a HumanBank")


func test_target_tables_agree() -> void:
	var n: int = _bank.target_names.size()
	assert_gt(n, 0)
	for table in [_bank.target_scale, _bank.target_delta_start, _bank.target_count, _bank.target_sparse_start]:
		assert_eq(table.size(), n, "one entry per target")
	assert_eq(_bank.target_dense.size(), n)
	var sparse_total: int = 0
	var delta_total: int = 0
	for t in n:
		delta_total += _bank.target_count[t] * 3
		if _bank.target_dense[t] == 1:
			assert_eq(_bank.target_count[t], _bank.base.size(), "a dense target covers every vertex")
		else:
			assert_eq(_bank.target_sparse_start[t], sparse_total, "sparse runs are contiguous")
			sparse_total += _bank.target_count[t]
	assert_eq(_bank.sparse_index.size(), sparse_total * 2, "uint16 per sparse entry")
	assert_eq(_bank.delta.size(), delta_total * 2, "int16 x3 per moved vertex")


func test_every_slider_target_is_in_the_bank() -> void:
	var known: Dictionary = {}
	for key in _bank.target_names:
		known[key] = true
	for entry in _bank.catalogue:
		for key in entry["negative"] + entry["positive"]:
			assert_true(known.has(key), "slider %s needs target %s" % [entry["key"], key])


func test_every_asset_choice_has_a_mesh() -> void:
	for kind in _bank.asset_catalogue:
		if kind == "outfit":
			continue  # the outfits of version 6 and before: worn as garments now (test_every_garment_has_its_file)
		var choices: Array = _bank.asset_catalogue[kind]
		for slot in choices.size():
			var empty: bool = str(choices[slot]["id"]) == "none"
			var parts: Array[HumanAssetData] = _bank.assets_of(StringName(kind), slot)
			if empty:
				assert_eq(parts.size(), 0, "%s %s is the 'none' choice" % [kind, choices[slot]["id"]])
			else:
				assert_gt(parts.size(), 0, "%s %s needs its mesh" % [kind, choices[slot]["id"]])


func test_every_garment_has_its_file() -> void:
	var signature: String = GarmentFormat.bank_signature(_bank)
	for entry: Dictionary in CharacterAppearance.garment_entries():
		var g: HumanAssetData = GarmentLibrary.asset(String(entry["id"]))
		assert_not_null(g, "garment %s is imported (%s)" % [entry["id"], GarmentFormat.path_of(entry["id"])])
		if g == null:
			continue
		assert_eq(g.body_signature, signature, "%s is bound to this body" % entry["id"])
		assert_eq(Array(g.zones), entry["zones"], "%s: the catalogue's zones are the file's" % entry["id"])
		assert_eq([g.support, g.layer, g.access], [int(entry["support"]), int(entry["layer"]), int(entry["access"])],
				"%s: the catalogue's GDD code is the file's" % entry["id"])
		assert_not_null(g.albedo, "%s has its colours" % entry["id"])
		var n: int = g.offsets.size()
		assert_eq(g.refs.size(), n * 3, "%s refs" % entry["id"])
		assert_eq(g.weights.size(), n * 3, "%s weights" % entry["id"])
		for r in g.refs:
			if r < 0 or r >= _bank.base.size():
				fail_test("%s refers to body vertex %d" % [entry["id"], r])
				break
	for entry: Dictionary in _bank.asset_catalogue.get("outfit", []):
		for id: Variant in entry.get("garments", []):
			assert_ne(CharacterAppearance.garment_index(String(id)), -1, "outfit %s's garment %s" % [entry["id"], id])


func test_assets_are_well_formed() -> void:
	var vertex_count: int = _bank.base.size()
	for a in _bank.assets:
		var n: int = a.offsets.size()
		assert_eq(a.refs.size(), n * 3, "%s refs" % a.id)
		assert_eq(a.weights.size(), n * 3, "%s weights" % a.id)
		assert_eq(a.uv.size(), a.vertex.size(), "%s uv per render vertex" % a.id)
		assert_eq(a.bones.size(), a.vertex.size() * 4, "%s 4 bones per render vertex" % a.id)
		assert_eq(a.index.size() % 3, 0, "%s triangles" % a.id)
		assert_lt(_max(a.refs), vertex_count, "%s refs inside the compact vertices" % a.id)
		if a.style == &"strands":
			assert_eq(a.strand_points.size(), n * a.strand_size, "%s: its guides, one root bound each" % a.id)
		elif a.style != &"hairs":  # hairs are drawn without a texture
			assert_not_null(a.albedo, "%s has its texture" % a.id)


func test_the_skeleton_is_the_characters() -> void:
	# Joints and skin weights index these bones: they must be the bones the animation library drives.
	var body: Node = (load(CHARACTER_SCENE) as PackedScene).instantiate()
	var skeleton: Skeleton3D = body.find_children("*", "Skeleton3D", true, false)[0]
	for bone in _bank.bone_names:
		assert_ne(skeleton.find_bone(bone), -1, "bank bone %s exists on the character skeleton" % bone)
	assert_eq(_bank.joint_ptr.size(), _bank.bone_names.size() * 2 + 1, "a head and a tail run per bone")
	body.free()


func test_body_mesh_and_skin_sizes() -> void:
	assert_eq(_bank.body_uv.size(), _bank.body_vertex.size())
	assert_eq(_bank.body_tangent.size(), _bank.body_vertex.size() * 4)
	assert_eq(_bank.skin_bones.size(), _bank.base.size() * 4)
	assert_eq(_bank.skin_weights.size(), _bank.base.size() * 4)
	assert_eq(_bank.body_index.size() % 3, 0)


func _max(values: PackedInt32Array) -> int:
	var m: int = -1
	for v in values:
		m = maxi(m, v)
	return m
