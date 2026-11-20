class_name HumanBuilder
extends RefCounted

## Bakes one body: from an appearance's target weights to two skinned ArrayMeshes -- the body (one surface
## per material zone, plus the hair and the clothes) and the head (face, eyes, mouth, plus what grows on the
## face) -- their Skin, and the skeleton's new rest positions.
##
## The head is apart so that a face seen close up can come alive: a second bake of the head alone (a
## "live" order) gives it the blend shapes of LIFE_SHAPES -- blinks, gaze, mouth, brows -- which FaceLife
## drives. The two meet at the neck on vertices no shape moves, with normals taken over the whole body.
##
## Runs on a worker thread (HumanMeshCache): plain data in, Resources out, no node touched. Everything a
## build reads -- the bank, the morph, the per-bank topology below -- is made beforehand (prepare / warm)
## and only read afterwards.
##
## Poses: the base body (Vitruvian) rests in an A pose, arms down at 45 degrees. The game skeleton and its
## animation library rest in a T pose, with every bone's rest ROTATION the template skeleton's. So the mesh
## stays as modelled, and each bone's bind carries the turn from its A direction to the template's (as
## Godot's glTF importer does when it fixes a rest pose): a vertex v skinned to a bone at rest shows at
## T + Q (v - J), with J the joint on the mesh, Q that turn, and T the joint once every parent has turned.
## The rest rotations are untouched, so the library, the IKs and the bone attachments keep working.
##
## The trunk (TRUNK_BONES) does not turn: the template's spine is a straight vertical line, the body's an S,
## and its joints wander with the shape (a belly or buttocks pull the affine joints forward or back by up to
## 20 degrees). Turning each segment upright rotated it as a block about its joint: a back broken at the
## lumbar and under the neck. The trunk keeps the curve it was modelled (and morphed) with.

## One baked body, shared by every avatar with the same shape (HumanMeshCache).
class Baked:
	extends RefCounted
	## CharacterAppearance.shape_hash this body was baked for.
	var shape_hash: int = 0
	## The body below the neck, the hair and the clothes. Null in a live bake (the head alone).
	var mesh: ArrayMesh
	var skin: Skin
	## Per mesh surface: the worn asset it shows (HumanAssetData), or the body zone's name (StringName).
	var surface_assets: Array = []
	## The head: face, eyes, mouth, and the assets that grow on the face. In a live bake, with LIFE_SHAPES
	## as blend shapes and no level of detail.
	var head_mesh: ArrayMesh
	## Per head mesh surface: as surface_assets.
	var head_surface_assets: Array = []
	## Whether this is a live bake: the head alone, with its blend shapes.
	var live: bool = false
	## The hair, as hairs (HairStrands): one mesh per style, shared by everyone who wears it, unskinned --
	## it hangs on the Head bone. Null: no hair, or a style without strands (a buzz cut is all shell).
	var hair_mesh: ArrayMesh
	## Where the hair mesh sits under the Head bone: the fit of the style to this head, then the head's bind.
	var hair_transform := Transform3D.IDENTITY
	## The asset hair_mesh was made from (its material).
	var hair_asset: HumanAssetData
	## The capsules the hair keeps out of (HairMotion): [bone name, a, b (bone space), radius (m)] per bone.
	var hair_colliders: Array = []
	## Global rest of each bank bone (HumanBank.bone_names order), skeleton space, soles at y = 0.
	var rests: Array[Transform3D] = []
	## Height of the hips joint at rest (m): the skeleton's motion_scale.
	var hips_height: float = 1.0
	## Time the bake took on its worker (ms).
	var build_ms: float = 0.0
	## Whether the meshes have their levels of detail (a creator preview bakes without, for speed).
	var lods: bool = true


## What a build needs from an appearance, resolved on the main thread (catalogue and bank lookups).
class Order:
	extends RefCounted
	var shape_hash: int = 0
	var targets := PackedInt32Array()
	var weights := PackedFloat32Array()
	var assets: Array[HumanAssetData] = []
	## The head of hair, grown at bake time (HairGroom, on the worker) and worn at position [member hair_at]
	## among the assets; null: none.
	var hair_cut: HairCut = null
	var hair_at: int = 0
	## The beard, grown likewise (BeardGroom) and worn at [member beard_at]; null: none.
	var beard_cut: BeardCut = null
	var beard_at: int = 0
	## A garment hides the face (a closed helmet): nothing grows on it -- brows, lashes, beard.
	var hide_face: bool = false
	## Scale of the whole body (HumanMacros.stature).
	var stature: float = 1.0
	## Make levels of detail (~100 ms more): every avatar in the world; not the creator's preview.
	var lods: bool = true
	## Bake the head alone, with LIFE_SHAPES as blend shapes (a face seen close up).
	var live: bool = false


## Normals closer than this (deg) are merged when the LODs simplify the mesh (the glTF importer's default).
const LOD_NORMAL_MERGE_DEG: float = 25.0
## Deprecated by Godot, still passed: the importer's default.
const LOD_NORMAL_SPLIT_DEG: float = 60.0
## Kinds of worn assets, in the order their surfaces are added (garments inside out: GarmentLibrary.worn).
const WORN_KINDS: Array[String] = ["eyebrows", "eyelashes", "hair", "beard", "garment"]
## Worn assets that hang on the face's skin and move with it: in the head mesh, with its blend shapes.
const FACE_KINDS: Array[String] = ["eyebrows", "eyelashes", "beard"]
## The capsules a head of hair's strands keep out of (HairMotion), where long hair lies: [the bone that carries it (and
## whose skin and cloth measure its radius), the joints it runs between, optionally the band (m, up and down) of the
## skin measured]. The neck; the top of the chest across, from one shoulder joint to the other, measured at their
## height (a torso is wide and thin: round about its spine, it pushed the hair 20 cm off the back; measured all down
## the chest, 24 cm); the collarbones; the upper arms.
const HAIR_COLLIDERS: Array = [["Neck", "Neck", "Head"], ["UpperChest", "LeftUpperArm", "RightUpperArm", 0.05],
		["LeftShoulder", "LeftShoulder", "LeftUpperArm"], ["RightShoulder", "RightShoulder", "RightUpperArm"],
		["LeftUpperArm", "LeftUpperArm", "LeftLowerArm"], ["RightUpperArm", "RightUpperArm", "RightLowerArm"]]
## Material zones of the body mesh; every other zone (face, eyes, mouth...) is the head's.
const BODY_ZONES: Array[String] = ["Torso", "Arms", "Legs"]
## Bones that keep the body's own direction (no turn to the template's): the spine and the head.
const TRUNK_BONES: Array[StringName] = [&"Hips", &"Spine", &"Chest", &"UpperChest", &"Neck", &"Head"]
## The blend shapes of a live head, in order: [name, {bank target: weight}]. Sides are the CHARACTER's
## (its left is +X). Each is a sum of the base model's face units, so that one shape does one job: a
## glance to the left moves both eyes. Kept few -- a shape costs ~0.6 MB of video memory per live head.
const LIFE_SHAPES: Array = [
	[&"blink_left", {"FACS_Eyes_Closed_Right": 1.0}],
	[&"blink_right", {"FACS_Eyes_Closed_Left": 1.0}],
	[&"look_left", {"FACS_Look_In_Left": 1.0, "FACS_Look_Out_Right": 1.0}],
	[&"look_right", {"FACS_Look_Out_Left": 1.0, "FACS_Look_In_Right": 1.0}],
	[&"look_up", {"FACS_Look_Up_Left": 1.0, "FACS_Look_Up_Right": 1.0}],
	[&"look_down", {"FACS_Look_Dwn": 1.0}],
	[&"jaw_open", {"FACS_aa_02": 1.0}],
	[&"mouth_round", {"FACS_ow_08": 1.0}],
	[&"mouth_wide", {"FACS_y_iy_ih_ix_06": 1.0}],
	[&"mouth_closed", {"FACS_p_b_m_21": 1.0}],
	[&"smile", {"FACS_Smile_Lips_Closed": 1.0}],
	[&"brows_up", {"FACS_Eyebrows_Raised_Left": 1.0, "FACS_Eyebrows_Raised_Right": 1.0}],
	[&"brows_frown", {"FACS_Eyebrows_Frown_Left": 1.0, "FACS_Eyebrows_Frown_Right": 1.0}],
	[&"squint", {"FACS_Eyes_Squint": 1.0}],
	[&"happy", {"FACS_Happy": 1.0}],
	[&"sad", {"FACS_Sad": 1.0}],
	[&"angry", {"FACS_Angry": 1.0}],
]

## Make levels of detail when an order asks for them (tests turn it off: it is most of a bake's time).
static var generate_lods: bool = true
static var _prepared: bool = false
static var _warm_task: int = -1  # -1 = never started, -2 = finished, else the WorkerThreadPool task
static var _target_slot: Dictionary = {}  # target key -> bank index
static var _body_index := PackedInt32Array()  # clockwise, over ALL render vertices (for the normals)
static var _zone_index: Array[PackedInt32Array] = []  # per zone: clockwise, over the zone's own vertices
static var _zone_map: Array[PackedInt32Array] = []  # per zone: its render vertices' compact vertices
static var _body_bones := PackedInt32Array()  # 4 per render vertex
static var _body_weights := PackedFloat32Array()
static var _asset_topology: Dictionary = {}  # HumanAssetData instance id -> [index cw, bones int32]
static var _hips: int = -1
static var _trunk := PackedByteArray()  # per bank bone: 1 for a TRUNK_BONES bone (never turned)
static var _is_head := PackedByteArray()  # per zone: 1 when it is the head's
static var _head_first := PackedInt32Array()  # per zone: its first vertex among the head's (-1: a body zone)
static var _head_map := PackedInt32Array()  # the head's render vertices' compact vertices, zone after zone
static var _head_index := PackedInt32Array()  # the head's triangles (clockwise) over those
static var _head_tangent := PackedFloat32Array()
static var _head_border := PackedInt32Array()  # head vertices the body shares (the neck): no shape moves them
static var _head_border_rest := PackedInt32Array()  # the same vertices among ALL the render vertices
static var _life_targets: Array = []  # per LIFE_SHAPES entry: [bank targets, weights]


## Get the shared read-only data ready WITHOUT blocking: the first call starts loading it on a worker,
## later calls tell whether it is done. Main thread. A puppet keeps the imported body meanwhile.
static func warm() -> bool:
	if _prepared:
		return true
	if _warm_task == -1:
		# The C# twins are made here, on the main thread; the workers only fill them.
		var native: Object = HumanMorph.native_instance()
		HairGroom.adopt_native(HairGroom.native_instance())
		HairMotionBinding.adopt_native(HairMotionBinding.native_instance())
		_warm_task = WorkerThreadPool.add_task(_prepare_now.bind(native), false, "HumanBuilder.warm")
		return false
	if _warm_task >= 0 and WorkerThreadPool.is_task_completed(_warm_task):
		WorkerThreadPool.wait_for_task_completion(_warm_task)
		_warm_task = -2
	return _prepared


## The shared read-only data, made now if needed (waiting for warm()'s worker when it runs). Main thread.
static func prepare() -> HumanMorph:
	if not _prepared:
		if _warm_task >= 0:
			WorkerThreadPool.wait_for_task_completion(_warm_task)
			_warm_task = -2
		else:
			HairGroom.adopt_native(HairGroom.native_instance())
			HairMotionBinding.adopt_native(HairMotionBinding.native_instance())
			_prepare_now(HumanMorph.native_instance())
	return HumanMorph.shared()


static func _prepare_now(native: Object) -> void:
	var bank := load(HumanBank.PATH) as HumanBank
	var morph := HumanMorph.new(bank, native)
	for i in bank.target_names.size():
		_target_slot[bank.target_names[i]] = i
	var zones: int = bank.zone_names.size()
	var local: PackedInt32Array = _clockwise(bank.body_index)
	_body_index = local.duplicate()
	for z in zones:
		var first: int = bank.zone_vertex_ptr[z]
		var a: int = bank.zone_index_ptr[z]
		var b: int = bank.zone_index_ptr[z + 1]
		for k in range(a, b):
			_body_index[k] += first
		_zone_index.append(local.slice(a, b))
		_zone_map.append(bank.body_vertex.slice(first, bank.zone_vertex_ptr[z + 1]))
	var n: int = bank.body_vertex.size()
	_body_bones.resize(n * 4)
	_body_weights.resize(n * 4)
	for i in n:
		var v: int = bank.body_vertex[i]
		for k in 4:
			_body_bones[i * 4 + k] = bank.skin_bones[v * 4 + k]
			_body_weights[i * 4 + k] = bank.skin_weights[v * 4 + k]
	for asset: HumanAssetData in bank.assets:
		_asset_topology[asset.get_instance_id()] = _topology_of(asset)
	_hips = bank.bone_names.find("Hips")
	_trunk.resize(bank.bone_names.size())
	for b in bank.bone_names.size():
		_trunk[b] = 1 if TRUNK_BONES.has(StringName(bank.bone_names[b])) else 0
	_split_head(bank)
	CharacterMaterials.warm_textures()
	HumanMorph.set_shared(morph)
	_prepared = true


## The head's own topology: its zones' vertices and triangles in one run (a shape's normals are taken over
## the head alone), the vertices it shares with the body, and the bank targets of each life shape.
static func _split_head(bank: HumanBank) -> void:
	var in_body := PackedByteArray()
	in_body.resize(bank.base.size())
	for z in bank.zone_names.size():
		var head: bool = not BODY_ZONES.has(bank.zone_names[z])
		_is_head.append(1 if head else 0)
		_head_first.append(_head_map.size() if head else -1)
		var a: int = bank.zone_vertex_ptr[z]
		var b: int = bank.zone_vertex_ptr[z + 1]
		if not head:
			for i in range(a, b):
				in_body[bank.body_vertex[i]] = 1
			continue
		for k in _zone_index[z]:
			_head_index.append(k + _head_first[z])
		_head_map.append_array(bank.body_vertex.slice(a, b))
		_head_tangent.append_array(bank.body_tangent.slice(a * 4, b * 4))
	for z in bank.zone_names.size():
		if _is_head[z] == 0:
			continue
		for i in range(bank.zone_vertex_ptr[z], bank.zone_vertex_ptr[z + 1]):
			if in_body[bank.body_vertex[i]]:
				_head_border.append(_head_first[z] + i - bank.zone_vertex_ptr[z])
				_head_border_rest.append(i)
	for shape: Array in LIFE_SHAPES:
		var targets := PackedInt32Array()
		var weights := PackedFloat32Array()
		for key: String in shape[1]:
			var slot: int = _target_slot.get(key, -1)
			if slot != -1:
				targets.append(slot)
				weights.append(shape[1][key])
		_life_targets.append([targets, weights])


## The build order of an appearance (main thread): its weighted targets and the meshes it wears.
## [param live]: the head alone, with its blend shapes (LIFE_SHAPES).
static func order_for(appearance: CharacterAppearance, lods: bool = true, live: bool = false) -> Order:
	var bank: HumanBank = prepare().bank
	var order := Order.new()
	order.shape_hash = appearance.shape_hash()
	order.lods = lods and not live
	order.live = live
	order.stature = HumanMacros.stature(appearance.macros["height"])
	var stack: Array = HumanMacros.target_stack(bank.macro_config, appearance.macros, appearance.origins)
	stack.append_array(appearance.modifier_stack())
	for pair: Array in stack:
		var slot: int = _target_slot.get(pair[0], -1)
		if slot == -1:
			continue  # a slider newer than the bank
		order.targets.append(slot)
		order.weights.append(pair[1])
	var picks: Dictionary = {"eyebrows": appearance.eyebrows, "eyelashes": appearance.eyelashes, "hair": appearance.hair,
			"beard": appearance.beard}
	order.hide_face = appearance.garments_hide("face")
	for kind in WORN_KINDS:
		if kind == "hair":  # grown from its settings, unless a helmet or a hat hides it
			order.hair_cut = null if order.hide_face or appearance.garments_hide("hair") else appearance.hair_cut()
			order.hair_at = order.assets.size()
			continue
		if kind == "beard":
			order.beard_cut = null if order.hide_face or appearance.garments_hide("beard") else appearance.beard_grown()
			order.beard_at = order.assets.size()
			continue
		if kind == "garment":
			order.assets.append_array(GarmentLibrary.worn(appearance))
			continue
		if order.hide_face and FACE_KINDS.has(kind):
			continue
		order.assets.append_array(bank.assets_of(kind, picks[kind]))
	return order


## Bake a body (any thread, after prepare()). template: the template skeleton's global rest of each bank
## bone (its rotations are kept, its bone directions are the T pose the body is turned to).
static func build(order: Order, template: Array[Transform3D]) -> Baked:
	var started: int = Time.get_ticks_usec()
	var morph: HumanMorph = HumanMorph.shared()
	var bank: HumanBank = morph.bank
	var points: PackedVector3Array = morph.morph(order.targets, order.weights)
	if not is_equal_approx(order.stature, 1.0):
		for i in points.size():
			points[i] *= order.stature

	var baked := Baked.new()
	baked.shape_hash = order.shape_hash
	var joints: PackedVector3Array = _pose_skeleton(baked, bank, points, template)

	baked.live = order.live
	var worn: Array[HumanAssetData] = order.assets.duplicate()
	# Grown hair goes where its kind is in WORN_KINDS: the beard after the hair, so insert it first.
	if order.beard_cut != null:
		var beard: Array[HumanAssetData] = BeardGroom.assets_for(order.beard_cut)
		for k in beard.size():
			worn.insert(order.beard_at + k, beard[k])
	if order.hair_cut != null and not order.live:
		var hair: Array[HumanAssetData] = HairGroom.assets_for(order.hair_cut)
		for k in hair.size():
			worn.insert(order.hair_at + k, hair[k])
	if not order.live:
		baked.hair_colliders = _hair_colliders(baked, bank, morph, points, joints, worn)
	var hidden := PackedByteArray()
	hidden.resize(points.size())
	for asset in worn:
		for v in asset.delete:
			hidden[v] = 1
	# A garment under another is not drawn where it hangs on skin the one over it hides (a trouser leg in a boot).
	var under: Dictionary = {}  # garment instance id -> per garment vertex, 1 when hidden by those over it
	var over := PackedByteArray()
	over.resize(points.size())
	var covered: bool = false
	for k in range(worn.size() - 1, -1, -1):
		var garment: HumanAssetData = worn[k]
		if garment.kind != &"garment":
			continue
		if covered:
			under[garment.get_instance_id()] = GarmentLibrary.hidden_under(garment, over)
		for v in garment.delete:
			over[v] = 1
		covered = covered or not garment.delete.is_empty()
	# Normals over ALL the body's triangles (no crease at a zone's edge, nor at the neck), then one
	# surface per zone, drawn where no outfit hides it.
	var body: Array = morph.surface(points, bank.body_vertex, _body_index, bank.body_tangent, Vector3.ZERO)
	# A live head: every life shape as the body with it at full weight (blend shape data is absolute, as
	# Godot's glTF importer gives it).
	var moved_points: Array[PackedVector3Array] = []
	var moved_head: Array = []
	if order.live:
		for pair: Array in _life_targets:
			var moved: PackedVector3Array = points
			for k in (pair[0] as PackedInt32Array).size():
				moved = morph.with_target(moved, pair[0][k], pair[1][k] * order.stature)
			moved_points.append(moved)
			moved_head.append(_head_shape(morph, moved, body))

	var body_importer := ImporterMesh.new()
	var head_importer := ImporterMesh.new()
	var late_body: Array = []  # [asset, arrays, blend shapes] of the surfaces that bring their own LODs
	var late_head: Array = []
	if order.live:
		for shape: Array in LIFE_SHAPES:
			head_importer.add_blend_shape(shape[0])
	for z in bank.zone_names.size():
		var head: bool = _is_head[z] != 0
		if order.live and not head:
			continue
		var a: int = bank.zone_vertex_ptr[z]
		var b: int = bank.zone_vertex_ptr[z + 1]
		var visible: PackedInt32Array = morph.visible_triangles(_zone_index[z], _zone_map[z], hidden)
		if visible.is_empty():
			continue
		var shapes: Array = []
		for full: Array in moved_head:
			shapes.append(_slice(full, _head_first[z], _head_first[z] + b - a))
		_add_surface(head_importer if head else body_importer, _slice(body, a, b), bank.body_uv.slice(a, b), visible,
				_body_bones.slice(a * 4, b * 4), _body_weights.slice(a * 4, b * 4), bank.zone_names[z], PackedColorArray(), shapes)
		(baked.head_surface_assets if head else baked.surface_assets).append(StringName(bank.zone_names[z]))
	for asset in worn:
		var on_face: bool = FACE_KINDS.has(String(asset.kind))
		if order.live and not on_face:
			continue
		if asset.style == &"strands":
			_place_hair(baked, morph, points, asset)
			continue
		var topology: Array = _asset_topology.get(asset.get_instance_id(), [])
		if topology.is_empty() and asset.kind == &"garment":
			topology = GarmentLibrary.topology(asset)
		if topology.is_empty():  # grown at runtime (HairGroom): not in the bank
			topology = _topology_of(asset)
		var drawn: PackedInt32Array = topology[0]
		if under.has(asset.get_instance_id()):
			drawn = morph.visible_triangles(drawn, asset.vertex, under[asset.get_instance_id()])
			if drawn.is_empty():
				continue
		var arrays: Array = _asset_surface(morph, points, asset, topology[0])
		var shapes: Array = []
		for moved in moved_points:
			shapes.append(_asset_surface(morph, moved, asset, topology[0]))
		if asset.lods.is_empty():
			_add_surface(head_importer if on_face else body_importer, arrays, asset.uv, drawn, topology[1],
					asset.bone_weights, "%s:%s:%d" % [asset.kind, asset.id, asset.part], asset.color, shapes)
			(baked.head_surface_assets if on_face else baked.surface_assets).append(asset)
		else:  # its own levels of detail: added once the engine has made the others'
			(late_head if on_face else late_body).append([asset, _surface_arrays(arrays, asset.uv, topology[0], topology[1],
					asset.bone_weights, asset.color), _blend_arrays(shapes)])

	# Levels of detail (meshoptimizer, as the glTF importer makes them): a body is ~75 k triangles, an
	# avatar across the street needs a few thousand. On the worker, once per shape. A live head has none:
	# it is only shown close up.
	baked.lods = generate_lods and order.lods
	if baked.lods:
		body_importer.generate_lods(LOD_NORMAL_MERGE_DEG, LOD_NORMAL_SPLIT_DEG, [])
		head_importer.generate_lods(LOD_NORMAL_MERGE_DEG, LOD_NORMAL_SPLIT_DEG, [])
	if not order.live:
		baked.mesh = body_importer.get_mesh()
		_add_late(baked.mesh, late_body, baked.surface_assets, baked.lods)
	baked.head_mesh = head_importer.get_mesh()
	_add_late(baked.head_mesh, late_head, baked.head_surface_assets, baked.lods)
	baked.build_ms = (Time.get_ticks_usec() - started) / 1000.0
	return baked


## The hair of a style on this head: the style's shared mesh, and the transform that carries its roots to
## where they land on this scalp (HairStrands.fit), under the Head bone.
static func _place_hair(baked: Baked, morph: HumanMorph, points: PackedVector3Array, asset: HumanAssetData) -> void:
	var head: int = morph.bank.bone_names.find("Head")
	if head == -1 or asset.strand_size < 2:
		return
	baked.hair_asset = asset
	baked.hair_mesh = HairStrands.mesh_of(asset)
	var on_this_head: Transform3D = HairStrands.fit(HairStrands.neutral_roots(asset), morph.fit(points, asset))
	baked.hair_transform = baked.skin.get_bind_pose(head) * on_this_head


## [positions, normals, tangents] of a worn asset fitted on a body. An asset that brings its normals (hair)
## keeps them, and its tangents: only its vertices follow the body.
static func _asset_surface(morph: HumanMorph, points: PackedVector3Array, asset: HumanAssetData, index: PackedInt32Array) -> Array:
	var fitted: PackedVector3Array = morph.fit(points, asset)
	if asset.normal_fixed.size() == asset.vertex.size() and fitted.size() == asset.vertex.size():
		return [fitted, asset.normal_fixed, asset.tangent]
	return morph.surface(fitted, asset.vertex, index, asset.tangent, Vector3.ZERO)


## [positions, normals, tangents] of the head's render vertices for a moved body: normals over the head's
## own triangles, and the neck's vertices exactly as the whole body gave them at rest ([param body]).
static func _head_shape(morph: HumanMorph, moved: PackedVector3Array, body: Array) -> Array:
	var out: Array = morph.surface(moved, _head_map, _head_index, _head_tangent, Vector3.ZERO)
	var pos: PackedVector3Array = out[0]
	var nrm: PackedVector3Array = out[1]
	var tan: PackedFloat32Array = out[2]
	for n in _head_border.size():
		var i: int = _head_border[n]
		var r: int = _head_border_rest[n]
		pos[i] = body[0][r]
		nrm[i] = body[1][r]
		for k in 4:
			tan[i * 4 + k] = body[2][r * 4 + k]
	return [pos, nrm, tan]


## A run of render vertices of a [positions, normals, tangents] surface.
static func _slice(surface: Array, a: int, b: int) -> Array:
	return [(surface[0] as PackedVector3Array).slice(a, b), (surface[1] as PackedVector3Array).slice(a, b),
			(surface[2] as PackedFloat32Array).slice(a * 4, b * 4)]


## The capsules a head of hair's strands keep out of (HairMotion): per bone of HAIR_COLLIDERS, [bone name, the
## segment from its joint to its child's (in the bone's own space: the skeleton's pose carries it), radius (m)] --
## the radius the 90th percentile of how far the body's skin and the garments' cloth on that bone lie from the
## segment: a thick collar makes a thicker neck.
static func _hair_colliders(baked: Baked, bank: HumanBank, morph: HumanMorph, points: PackedVector3Array,
		joints: PackedVector3Array, worn: Array[HumanAssetData]) -> Array:
	var bones: Dictionary = {}  # bone index -> [from joint, to joint, body distances, cloth distances]
	for entry: Array in HAIR_COLLIDERS:
		var b: int = bank.bone_names.find(entry[0])
		var from: int = bank.bone_names.find(entry[1])
		var to: int = bank.bone_names.find(entry[2])
		if b != -1 and from != -1 and to != -1:
			# Arrays: a Packed one in an Array is a copy, appends to it are lost.
			bones[b] = [joints[from], joints[to], [], [], float(entry[3]) if entry.size() > 3 else INF]
	for v in points.size():
		var b: int = bank.skin_bones[v * 4]
		if bones.has(b) and bank.skin_weights[v * 4] >= 0.5:
			_collider_sample(bones[b], 2, points[v])
	for asset in worn:
		if not (asset.kind == &"outfit" or asset.kind == &"garment") or asset.bones.is_empty():
			continue
		var fitted: PackedVector3Array = morph.fit(points, asset)
		for r in asset.vertex.size():
			var b: int = asset.bones[r * 4]
			if bones.has(b) and asset.bone_weights[r * 4] >= 0.5:
				_collider_sample(bones[b], 3, fitted[asset.vertex[r]])
	var out: Array = []
	for b: int in bones:
		var radius: float = maxf(_percentile(bones[b][2], 0.9), _percentile(bones[b][3], 0.9))
		if radius <= 0.0:
			continue
		var bind: Transform3D = baked.skin.get_bind_pose(b)
		out.append([bank.bone_names[b], bind * (bones[b][0] as Vector3), bind * (bones[b][1] as Vector3), radius])
	return out


static func _collider_sample(entry: Array, slot: int, p: Vector3) -> void:
	var a: Vector3 = entry[0]
	var ab: Vector3 = (entry[1] as Vector3) - a
	var t: float = (p - a).dot(ab) / maxf(ab.length_squared(), 1e-12)
	if t >= 0.0 and t <= 1.0 and absf(p.y - (a.y + ab.y * t)) <= float(entry[4]):
		(entry[slot] as Array).append(p.distance_to(a + ab * t))


static func _percentile(values: Array, share: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := PackedFloat32Array(values)
	sorted.sort()
	return sorted[mini(int(share * sorted.size()), sorted.size() - 1)]


## The skeleton of a body: joints on the mesh (A pose), each bone's turn to the template's direction, the
## T-pose rests with the soles on y = 0, and the binds that carry mesh vertices there.
static func _pose_skeleton(baked: Baked, bank: HumanBank, points: PackedVector3Array,
		template: Array[Transform3D]) -> PackedVector3Array:
	var count: int = bank.bone_names.size()
	var weighted: bool = bank.joint_weight.size() == bank.joint_index.size()
	var joints := PackedVector3Array()
	joints.resize(count)
	for b in count:
		var a: int = bank.joint_ptr[b * 2]
		var e: int = bank.joint_ptr[b * 2 + 1]
		var at := Vector3.ZERO
		for k in range(a, e):
			at += points[bank.joint_index[k]] * (bank.joint_weight[k] if weighted else 1.0 / float(e - a))
		joints[b] = at
	var parent_of := PackedInt32Array()
	parent_of.resize(count)
	for b in count:
		parent_of[b] = bank.bone_names.find(bank.bone_parents[b])
	# Bones are listed parents first. A bone with no child to aim at turns with its parent.
	var turns: Array[Basis] = []
	var rests := PackedVector3Array()
	turns.resize(count)
	rests.resize(count)
	for b in count:
		var p: int = parent_of[b]
		var aim: int = bank.bone_aim[b] if b < bank.bone_aim.size() else -1
		turns[b] = turns[p] if p != -1 else Basis.IDENTITY
		var trunk: bool = b < _trunk.size() and _trunk[b] == 1
		if aim != -1 and not trunk and b < template.size() and aim < template.size():
			var from: Vector3 = joints[aim] - joints[b]
			var to: Vector3 = template[aim].origin - template[b].origin
			if from.length_squared() > 1e-12 and to.length_squared() > 1e-12:
				turns[b] = Basis(Quaternion(from.normalized(), to.normalized()))
		rests[b] = rests[p] + turns[p] * (joints[b] - joints[p]) if p != -1 else joints[b]
	# The soles, once the legs are turned: the lowest stands on y = 0.
	var ground: float = INF
	for v in bank.sole_vertex:
		var b: int = bank.skin_bones[v * 4]
		ground = minf(ground, (rests[b] + turns[b] * (points[v] - joints[b])).y)
	if ground == INF:
		ground = 0.0
	baked.skin = Skin.new()
	for b in count:
		var rest := Transform3D(template[b].basis if b < template.size() else Basis.IDENTITY, rests[b] - Vector3(0.0, ground, 0.0))
		var carry := Transform3D(turns[b], rest.origin - turns[b] * joints[b])  # v -> T + Q (v - J)
		baked.rests.append(rest)
		baked.skin.add_named_bind(bank.bone_names[b], rest.affine_inverse() * carry)
	baked.hips_height = baked.rests[_hips].origin.y if _hips != -1 else 1.0
	return joints


static func _add_surface(importer: ImporterMesh, surface: Array, uv: PackedVector2Array, index: PackedInt32Array,
		bones: PackedInt32Array, weights: PackedFloat32Array, surface_name: String,
		colors := PackedColorArray(), shapes: Array = []) -> void:
	importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, _surface_arrays(surface, uv, index, bones, weights, colors),
			_blend_arrays(shapes), {}, null, surface_name)


static func _surface_arrays(surface: Array, uv: PackedVector2Array, index: PackedInt32Array, bones: PackedInt32Array,
		weights: PackedFloat32Array, colors: PackedColorArray) -> Array:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = surface[0]
	arrays[Mesh.ARRAY_NORMAL] = surface[1]
	arrays[Mesh.ARRAY_TANGENT] = surface[2]
	arrays[Mesh.ARRAY_TEX_UV] = uv
	if not colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	arrays[Mesh.ARRAY_INDEX] = index
	return arrays


static func _blend_arrays(shapes: Array) -> Array:
	var blend: Array = []
	for shape: Array in shapes:
		var data: Array = []
		data.resize(Mesh.ARRAY_MAX)
		data[Mesh.ARRAY_VERTEX] = shape[0]
		data[Mesh.ARRAY_NORMAL] = shape[1]
		data[Mesh.ARRAY_TANGENT] = shape[2]
		blend.append(data)
	return blend


## Add to a finished mesh the surfaces that bring their own levels of detail (HumanAssetData.lods: hair):
## each level draws the first share of the surface's triangles.
static func _add_late(mesh: ArrayMesh, late: Array, surface_assets: Array, with_lods: bool) -> void:
	for entry: Array in late:
		var asset: HumanAssetData = entry[0]
		var index: PackedInt32Array = entry[1][Mesh.ARRAY_INDEX]
		var lods: Dictionary = {}
		if with_lods:
			for k in range(0, asset.lods.size() - 1, 2):
				var kept: int = int(index.size() / 3.0 * asset.lods[k + 1]) * 3
				if kept >= 3:
					lods[asset.lods[k]] = index.slice(0, kept)
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, entry[1], entry[2], lods)
		mesh.surface_set_name(mesh.get_surface_count() - 1, "%s:%s:%d" % [asset.kind, asset.id, asset.part])
		surface_assets.append(asset)


## [triangles clockwise, skin bones as int32] of a worn asset (GarmentLibrary keeps its garments').
## The source triangles are counter-clockwise; Godot's front faces are clockwise.
static func topology_of(asset: HumanAssetData) -> Array:
	return _topology_of(asset)


static func _topology_of(asset: HumanAssetData) -> Array:
	var bones := PackedInt32Array()
	bones.resize(asset.bones.size())
	for k in asset.bones.size():
		bones[k] = asset.bones[k]
	return [_clockwise(asset.index), bones]


static func _clockwise(index: PackedInt32Array) -> PackedInt32Array:
	var out := index.duplicate()
	for t in range(0, out.size() - 2, 3):
		out[t + 1] = index[t + 2]
		out[t + 2] = index[t + 1]
	return out
