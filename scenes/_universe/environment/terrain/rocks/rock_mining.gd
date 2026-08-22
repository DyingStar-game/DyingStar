@tool
class_name RockMining
extends GenericProp

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")

# Max distance (rock-local) from the aim point to the active crack plane for the hit
# to count as "on the crack". Aiming farther than this = not on a crack -> no cut.
const FAULT_HIT_THRESHOLD := 0.05
# What a player can pick up — and therefore what the whole mining loop aims at. They are also the
# ONLY breakability threshold: "is this piece still worth cutting?" is answered by "can the player
# carry it yet?" (see _is_breakable_piece), so the mining loop closes by construction for every
# mineral, whatever its density. Both must pass: a long thin flake is unwieldy even when it is
# light.
const CARRY_MAX_SIZE := 1.0    # metres, longest side of the piece
const CARRY_MAX_MASS := 200.0  # kg
# Fraction of a piece's bounding box that is actually solid: a rock does not fill its box, so the
# raw AABB volume overestimates its mass by roughly a factor two.
const VOLUME_FILL := 0.5
# Fallback host-rock density (kg/m3, granite) for a rock whose spawner replicated no inert_density.
const INERT_DENSITY_DEFAULT := 2700.0

# Legacy ore look — FALLBACK only, used when no MineralDef is assigned (see `mineral`). The
# real look now comes from MineralDef (.tres). Purity thresholds below drive ore_threshold:
# ORE_T_RICH = full of ore, ORE_T_POOR = almost none.
const ORE_COLOR := Color(0.1, 0.8, 0.2)
const ORE_SCALE := 6.0
const ORE_SOFTNESS := 0.156
const ORE_METALLIC := 1.0
const ORE_ROUGHNESS := 0.059
const ORE_EMISSION := 9.3
const ORE_T_RICH := 0.40
const ORE_T_POOR := 0.72

## Neutral fault grooves — they deliberately do NOT reveal the mineral. Width of the crack, the
## colour showing at its bottom, and the carved depth (negative = raised instead of dug). The colour
## is a real hue rather than a darkening factor: a pure black crack read as a hole punched in the
## rock. It is applied with the sRGB `source_color` hint, so what you pick is what you see.
@export var groove_width: float = 0.005
@export var groove_color: Color = Color("3f1f06")
@export var groove_strength: float = 0.1

## Crack irregularity — what turns the fault from a ruled line into a fracture. The shader WARPS the
## plane distance with object-space noise before thresholding it: `crack_warp_freq` sets how tight
## the meanders are, `crack_warp_amp` how far the crack wanders off its plane (rock-local metres,
## 0 gives the old straight line back), `crack_width_var` how much the groove width breathes along
## it. Same value on server and client, so the aim tolerance below stays in step (_fault_tolerance).
@export var crack_warp_freq: float = 9.0
@export var crack_warp_amp: float = 0.045
@export_range(0.0, 1.0) var crack_width_var: float = 0.7

# Fracture history
var fractures: Array = []

## Replicated per-rock ore seed (network def "miningrock" -> ore_seed). MiningZone picks it so the
## rock's derived richness lands near the zone target, and every piece cut off this rock INHERITS it
## — so the 3D ore field is identical across the pieces and cutting only REVEALS ore, never re-rolls
## it. Empty falls back to the uuid (a rock spawned outside a zone).
## TEMPORARY (cut diagnosis): counts overlapping _apply_cuts runs on one rock. server.gd calls
## client_channel_data_update twice per spawn (before and after add_child), so a freshly split half
## can have two replays in flight at once — each clearing the other's subtraction boxes.
var _apply_cuts_seq: int = 0

## Signature of the cut history the geometry currently shows. `fractures` rides a 3 Hz replication
## channel, so the same unchanged list arrives over and over; replaying it each time re-bakes the
## whole CSG for nothing (measured: 42 replays on ONE rock in a single session).
var _applied_cut_signature: String = ""
## Re-entrancy guard. _apply_cuts is a coroutine that CLEARS every subtraction box before re-adding
## them a frame later, so two overlapping runs let the second wipe what the first is about to
## restore — the rock then renders whole, permanently and at random. Measured up to 4 in flight.
var _apply_cuts_running: bool = false
var _apply_cuts_dirty: bool = false

var ore_seed: String = ""

## Density (kg/m3) of the BARREN rock carrying the ore — replicated per rock ("inert_density" in the
## miningrock network def) because the gangue differs from one vein to the next. Mixed with the
## mineral's own density, each weighed on its own volume — see real_mass().
var inert_density: float = INERT_DENSITY_DEFAULT

## The barren mineral the gangue is made of — the local geology, replicated as "host_rock_id" by
## whoever spawned the rock (MiningZone reads it from the planet). It drives the EXTERIOR look:
## texture, relief and finish. Null on a rock spawned without one, and then the exterior falls back
## to the ore mineral's own rock_* fields, which is what every rock did before host rocks existed.
var host_rock: MineralDef = null

# variable to define if can be breakable. It's false if rock too small
var can_be_breakable: bool = false

# Server proximity-collision state (see server_update_proximity): the collider's real layers, and
# whether they are currently zeroed (rock dropped out of the broadphase because no player is near).
var _coll_layer: int = 1
var _coll_mask: int = 1
var _coll_disabled: bool = false

@export var mineral: MineralDef = MineralRegistry.GOLD

#####################################################################
# Common part
#####################################################################

func _ready() -> void:
	if Engine.is_editor_hint():
		# @tool script: the editor runs _ready() too, and there it has neither the autoloads
		# (GameOrchestrator / NetworkOrchestrator) nor a game SceneTree. Fit the collider so the
		# rock looks right in the viewport, and stop before anything touches the game.
		_build_mesh_collider()
		return

	# Everything from here to the end of _ready is what a rock costs the client the moment it lands.
	# Reported as `rock:ready` on the [CPerf+] line, with rock:hull / rock:material / rock:paint
	# breaking it down — see RockDebug.
	var _ready_tok := RockDebug.t()

	# GenericProp._ready resolves the PropSync child, which carries the networked `type_name`
	# ("miningrock") and `enable_carry` — both set per-scene in rock_mining_{sm,md,lg}.tscn.
	super._ready()

	# Continuous CD is a per-body cost in Jolt and these rocks never need it — they drop ~2 m at
	# low speed onto terrain and settle. With a full field (~1000 bodies) leaving it on dominates
	# the server's physics step even when every rock is asleep. Off here for both server + client.
	continuous_cd = false

	add_to_group("miningrock")  # for proximity detection (aim mode)
	add_to_group("carriable")  # so the carry pickup can resolve it by uuid (#124)

	# Physics OFF until the cut history has been replayed. A half just split off spawns at the exact
	# transform of the half it came from, and until _apply_cuts runs it is still geometrically the
	# WHOLE rock — handing that to Jolt for even one step makes the two pieces explode apart.
	if _has_pending_cuts():
		freeze = true

	# DIAGNOSIS (--rocks-no-csg): an uncut rock does not need a CSG node at all. Drop to a plain
	# MeshInstance3D sharing the one source mesh; _apply_cuts puts the CSG node back if a cut ever
	# has to be carved. Prices suspect 1 (per-rock CSG bake + per-rock unique ArrayMesh) on its own.
	if RockDebug.no_csg and not _has_pending_cuts():
		_ensure_csg_backend(false)

	# Build the collider from the actual rock mesh. The scene only ships a placeholder
	# sphere (radius 0.5 at the origin), far smaller than the visible rock — so the aim
	# raycast in MiningTool, which can only hit a physics collider, missed the surface and
	# never detected the rock when pointing at the perforate zone. A convex shape (required
	# for a RigidBody3D) matches the mesh closely enough for the aim ray to land on it.
	_build_mesh_collider()

	# Real mass from the spawn geometry, before anything else touches this body: the scene's
	# designer mass is only a placeholder. Recomputed whenever a replicated input arrives
	# (apply_prop_data) or the geometry changes (check_rock, after a cut).
	_refresh_mass()

	# Cut the rock if have fractures

	if OS.has_feature("dedicated_server"):
		_server_ready()
	else:
		_client_ready()
	RockDebug.t_end("rock:ready", _ready_tok)


## The rock's mesh node, found by TYPE and not by index: the scene ALSO holds a PropSync child
## (the networking component, see rock_mining_{sm,md,lg}.tscn) which sits at index 0, so
## get_child(0) returns the component instead of the mesh.
##
## Returns the base class, not CSGMesh3D, because an UNCUT rock may be rendered through a plain
## MeshInstance3D instead (see _ensure_csg_backend / RockDebug.no_csg): a CSG node re-bakes a whole
## new ArrayMesh per rock, which is exactly what the field spawn is being measured for.
func _mesh_node() -> GeometryInstance3D:
	for child in get_children():
		if child is CSGMesh3D or child is MeshInstance3D:
			return child as GeometryInstance3D
	return null


## The rock's SOURCE mesh — the shape before any cut. Same resource whichever backend renders it,
## and shared by every rock of the variant.
func _source_mesh() -> Mesh:
	var node := _mesh_node()
	if node is CSGMesh3D:
		return (node as CSGMesh3D).mesh
	if node is MeshInstance3D:
		return (node as MeshInstance3D).mesh
	return null


## The mesh AS IT IS RENDERED: the CSG bake result once cuts have been carved, the source mesh
## otherwise (and always, on the MeshInstance3D backend, which carves nothing).
func _rendered_mesh() -> Mesh:
	var node := _mesh_node()
	if node is CSGMesh3D:
		var baked: Array = (node as CSGMesh3D).get_meshes()
		if baked.size() > 1 and baked[1] is Mesh:
			return baked[1] as Mesh
	return _source_mesh()


## Paint the rock's surface, whichever backend carries it. CSGMesh3D takes a `material`; a
## MeshInstance3D has no such property and takes a surface override instead.
func _set_surface_material(mat: Material) -> void:
	var node := _mesh_node()
	if node is CSGMesh3D:
		(node as CSGMesh3D).material = mat
	elif node is MeshInstance3D:
		(node as MeshInstance3D).set_surface_override_material(0, mat)


## Swap the rock between its two rendering backends. CSG is only ever needed to CARVE — an uncut
## rock pays a full brush rebuild plus a unique baked ArrayMesh for a shape it never changes. So an
## uncut rock can ride a plain MeshInstance3D (sharing the one source mesh with every other rock),
## and the CSG node is put back the instant a cut has to be applied. No-op when the node already is
## what is wanted, so calling it on every path costs one type test.
func _ensure_csg_backend(want_csg: bool) -> void:
	var node := _mesh_node()
	if node == null or (node is CSGMesh3D) == want_csg:
		return
	var src: Mesh = _source_mesh()
	var replacement: GeometryInstance3D
	if want_csg:
		var csg := CSGMesh3D.new()
		csg.mesh = src
		replacement = csg
	else:
		var mi := MeshInstance3D.new()
		mi.mesh = src
		replacement = mi
	var node_name: String = node.name
	var node_xform: Transform3D = node.transform
	var node_override: Material = node.material_override
	var node_visible: bool = node.visible
	remove_child(node)
	node.queue_free()
	replacement.name = node_name
	replacement.transform = node_xform
	replacement.material_override = node_override
	replacement.visible = node_visible
	add_child(replacement)
	# The new node carries no surface material: whatever was painted is gone, so the next
	# _show_faults must rebuild rather than recognise its own signature and skip.
	_painted_signature = ""

## Fit the collider to the rock AS IT CURRENTLY IS. The scene only ships a placeholder sphere
## (radius 0.5 at the origin), far smaller than the visible rock, so the aim raycast — which can
## only hit a physics collider — missed the surface entirely.
##
## Built from the CSG RESULT, not from the source mesh: after a cut the piece is a fraction of the
## rock, and keeping the whole-rock hull would (a) leave the two halves deeply interpenetrating, so
## Jolt flings them apart on the first step, and (b) keep the ORIGINAL centre of mass — Godot derives
## it from the collision shapes — so the cut piece would never topple onto its new balance point.
func _build_mesh_collider() -> void:
	# DIAGNOSIS (--rocks-scene-hull): keep the shape authored in the scene and build no hull at all.
	# The authored shape is a placeholder sphere, so aiming and standing on rocks get worse —
	# measurement only, never a shipping mode.
	if RockDebug.scene_hull and not Engine.is_editor_hint():
		return
	var mesh_node := _mesh_node()
	if mesh_node == null:
		return
	var shape_node := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if shape_node == null:
		return
	var sc: float = _mesh_scale()
	var _tok := RockDebug.t()
	var shape: ConvexPolygonShape3D
	if _has_pending_cuts():
		# A piece that really was carved has geometry of its own, so it needs a hull of its own,
		# taken off the CSG RESULT. Plain QuickHull here (simplify=false): 1.7 ms for a 139-point
		# collider against 90 ms for a 32-point one, and a cut only ever happens on a player's
		# action, one piece at a time. A whole FIELD landing at once is the case that cannot afford
		# the expensive path — and it does not have to, see _shared_uncut_hull.
		var src: Mesh = _rendered_mesh()
		if src != null:
			shape = _scaled_hull(src.create_convex_shape(true, false), sc)
	else:
		shape = _shared_uncut_hull(_source_mesh(), sc)
	if shape != null:
		shape_node.shape = shape
	RockDebug.t_end("rock:hull", _tok)


## Scale a hull's points by the variant's factor (x1 sm, x1.2 md, x2 lg). The hull is measured on
## the mesh, in MESH-local space, while the CollisionShape3D hangs off the BODY — and scaling the
## shape NODE instead is what Jolt would rather we did not do.
static func _scaled_hull(shape: ConvexPolygonShape3D, sc: float) -> ConvexPolygonShape3D:
	if shape == null or is_equal_approx(sc, 1.0):
		return shape
	var pts: PackedVector3Array = shape.points
	for i in pts.size():
		pts[i] *= sc
	shape.points = pts
	return shape


## Uncut rocks: ONE hull for the whole game, per (source mesh, scale).
##
## Mesh.create_convex_shape(clean, simplify) does not simply hull the points when simplify is true —
## it runs the engine's convex DECOMPOSITION, measured at 90.3 ms on this 749-vertex mesh against
## 1.68 ms for the plain QuickHull (tools/perf/hull_stats.gd). Paid per rock, that WAS the cost of
## walking into a rock field: the client heartbeat put rock:hull at 95 ms of a 96 ms rock:ready, and
## running with --rocks-scene-hull took one rock from 99.6 ms to 0.7 ms and the field from 16 to
## 46 fps. Neither the CSG node (--rocks-no-csg), the per-rock material (--rocks-shared-mat) nor the
## rendering (--rocks-hidden) moved the number.
##
## The answer is not a cheaper hull — it is ONE hull. Every uncut rock of a variant is the same
## shape, so the expensive, and BETTER, 32-point collider is built on first use and handed to every
## rock after it. A Shape3D is a resource and the physics server is happy to share one between
## bodies, so this also spares a shape creation per rock. Keyed by scale as well as by mesh: the
## three variants share the one source mesh and differ only by that factor.
static var _hull_cache: Dictionary = {}

static func _shared_uncut_hull(src: Mesh, sc: float) -> ConvexPolygonShape3D:
	if src == null:
		return null
	# Falls back to the instance id for a mesh with no path — a shape built at runtime, which no
	# other rock can be sharing anyway, so it simply never hits the cache twice.
	var key: String = "%s@%.4f" % [src.resource_path if src.resource_path != "" else str(src.get_instance_id()), sc]
	if _hull_cache.has(key):
		return _hull_cache[key]
	var shape: ConvexPolygonShape3D = _scaled_hull(src.create_convex_shape(true, true), sc)
	if shape != null:
		_hull_cache[key] = shape
	return shape


## Replay every applied cut, in ONE pass.
##
## Every box is added, then the CALLER waits a single frame for the bake. This used to yield a frame
## per box, which cost N+1 frames of latency per replay (~135 ms on a six-cut rock at 52 fps) and
## N+1 CSG bakes over a growing tree — the brush work was quadratic in the number of cuts, and
## rock:cuts measured 298 ms per replay because of it.
##
## Batching is safe because _make_cut_box is pure local arithmetic: it reads the plane's own fields
## and the SOURCE mesh's AABB, never the body's transform and never the current CSG result. And CSG
## subtraction is commutative — the bake processes the whole child list at once, so insertion order
## cannot change the geometry.
##
## The pose is still parked per cut and saved/restored HERE, once. That save/restore is what the
## per-box await was really protecting: firing the coroutines without awaiting used to start the
## second before the first had restored anything, so it saved the CUT pose as its "original" and a
## piece with N cuts finished displaced into the frame of cut N-1. With one owner and no nesting,
## there is nothing left to serialise.
func _rebuild_fracture_all() -> void:
	var orig_position := position
	var orig_rotation := rotation
	for frac in fractures:
		if frac.get("fractured", false):
			_rebuild_fracture(frac)
	position = orig_position
	rotation = orig_rotation

## Drop every subtraction box currently under the mesh, so replaying the cuts is IDEMPOTENT. Without
## this, each `fractures` update stacked another box per already-applied cut — the geometry stayed
## right (subtracting the same region twice changes nothing) but the pile grew without bound.
func _clear_cut_boxes() -> void:
	var mesh_node := _mesh_node()
	if mesh_node == null:
		return
	for child in mesh_node.get_children():
		if child is CSGBox3D:
			mesh_node.remove_child(child)
			child.queue_free()

## Replay the WHOLE cut history onto the geometry and make the body match it again. This is the one
## entry point for "the fracture list changed" — at spawn (a rock restored from the database comes
## back WHOLE and replays its cuts here), on a replicated update, and right after a live cut.
##
## Physics is off for the entire operation and restored at the end: the piece changes shape, hull
## and centre of mass all at once, and letting Jolt see the intermediate states is what makes the
## halves explode apart. Coming back on with a NEW centre of mass is precisely what tips the piece
## over and lets it settle to sleep on its own.
## A signature of what the cut history WOULD carve, so an unchanged replicated list is recognised
## and skipped. Only the fields that shape the geometry take part.
func _cut_signature() -> String:
	var parts := PackedStringArray()
	for f in fractures:
		var d: Dictionary = f
		parts.append("%s,%s,%s,%s,%s,%s" % [
			d.get("fractured", false), d.get("keep_side", 1), d.get("plane_offset", 0.0),
			d.get("rotation_x", 0.0), d.get("rotation_y", 0.0), d.get("rotation_z", 0.0)])
	return "/".join(parts)


func _apply_cuts() -> void:
	# Nothing to redo: the geometry already shows exactly this history.
	var signature := _cut_signature()
	if signature == _applied_cut_signature:
		return
	# Already replaying. Remember that the list moved again and re-run ONCE at the end, instead of
	# racing the run in flight for ownership of the subtraction boxes.
	if _apply_cuts_running:
		_apply_cuts_dirty = true
		return
	# The history changed but carves NOTHING — the overwhelmingly common case, because a rock is born
	# with one un-fractured plane and gets a fresh one appended after every cut. The geometry is
	# already right, so the whole replay below (a frame of latency, and above all a SECOND QuickHull
	# over the 749-vertex mesh on top of the one _ready just ran) is pure waste, once per rock, in
	# the same frames a whole field is landing. The crack line the new plane draws is a MATERIAL
	# matter and is repainted by apply_prop_data -> _client_ready, not here.
	if not _has_pending_cuts():
		_applied_cut_signature = signature
		return
	_apply_cuts_running = true
	_applied_cut_signature = signature
	freeze = true
	# Wait our turn before touching the geometry — see _claim_replay_slot. Frozen and marked running
	# already, so a piece in the queue is inert, and a `fractures` update that lands while it waits
	# still sets _apply_cuts_dirty and gets replayed afterwards. Reported as `rock:cutqueue` on the
	# [CPerf+] line, kept OUT of `rock:cuts` so that one keeps measuring the carve and not the wait.
	var _queue_tok := RockDebug.t()
	while not _claim_replay_slot():
		await get_tree().process_frame
		# Unparented while queueing (zone exit, carried, freed): there is no geometry left to carve
		# and get_tree() is about to be null.
		if not is_inside_tree():
			# Forget the signature we optimistically claimed above: the geometry never got carved,
			# so a rock that does come back must not recognise this history as already applied.
			_applied_cut_signature = ""
			_apply_cuts_running = false
			RockDebug.t_end("rock:cutqueue", _queue_tok)
			return
	RockDebug.t_end("rock:cutqueue", _queue_tok)
	var _cut_tok := RockDebug.t()
	# A cut has to be CARVED, and only CSG carves. Puts the node back when the rock is riding the
	# plain MeshInstance3D backend (--rocks-no-csg); a no-op on the CSG backend.
	if _has_pending_cuts():
		_ensure_csg_backend(true)
	# TEMPORARY (cut diagnosis): a half that comes back WHOLE has to be told apart from one that was
	# never asked to cut. Records what the replay was given and what the CSG actually produced.
	#
	# Behind --rocks-verbose since the rock-field FPS work: EVERY print() in this project is routed
	# through CustomLogger -> Obs -> the C# OpenTelemetry bridge, so these four lines per rock are
	# not free diagnostics — on a field spawn they are a cost of their own.
	var _dbg := RockDebug.verbose_cuts
	var _dbg_pending: int = 0
	if _dbg:
		for _f in fractures:
			if _f.get("fractured", false):
				_dbg_pending += 1
	var _dbg_before: Vector3 = _piece_aabb().size if _dbg else Vector3.ZERO
	_apply_cuts_seq += 1
	var _dbg_seq: int = _apply_cuts_seq

	_clear_cut_boxes()
	_rebuild_fracture_all()
	# The subtraction boxes are in place but the CSG has not re-baked yet, so the hull and the AABB
	# below would still measure the WHOLE rock. Give it a frame.
	await get_tree().process_frame
	var _dbg_boxes: int = 0
	var _dbg_mesh := _mesh_node()
	if _dbg and _dbg_mesh != null:
		for _c in _dbg_mesh.get_children():
			if _c is CSGBox3D:
				_dbg_boxes += 1
	# TEMPORARY: dump the raw flag AND its type. The server sends `fractured` as a bool; if the
	# round-trip through Horizon turns it into a string, a number, or drops it, the replay silently
	# treats the plane as uncut — which is what the client is doing here.
	var _dbg_flags: Array = []
	if _dbg:
		for _f in fractures:
			var _v: Variant = (_f as Dictionary).get("fractured", "<absent>")
			_dbg_flags.append("%s(%s)" % [_v, type_string(typeof(_v))])
		print("[cut]   raw fractured=%s keep=%s seq=%s" % [
			_dbg_flags,
			fractures.map(func(f): return (f as Dictionary).get("keep_side", "<absent>")),
			fractures.map(func(f): return (f as Dictionary).get("seq", "<absent>"))])
	# TEMPORARY: what the CSG bake actually produced. Two surfaces with different ore_threshold
	# means the cut face really carries the inner (ore) material; ONE surface means every face got
	# painted with the same material and the reveal is gone whatever we set on the brush.
	if _dbg and not OS.has_feature("dedicated_server") and _dbg_mesh is CSGMesh3D:
		var _sur: Array = []
		for _m in (_dbg_mesh as CSGMesh3D).get_meshes():
			if _m is Mesh:
				for _i in (_m as Mesh).get_surface_count():
					var _mat := (_m as Mesh).surface_get_material(_i)
					var _thr: Variant = "-"
					if _mat is ShaderMaterial:
						_thr = (_mat as ShaderMaterial).get_shader_parameter("ore_threshold")
					_sur.append("s%d:thr=%s" % [_i, _thr])
		var _box_mats: int = 0
		for _c in _dbg_mesh.get_children():
			if _c is CSGBox3D and (_c as CSGBox3D).material != null:
				_box_mats += 1
		print("[cut]   bake surfaces=%s  node.material=%s override=%s boxes_with_material=%d/%d" % [
			_sur, (_dbg_mesh as CSGMesh3D).material != null, _dbg_mesh.material_override != null,
			_box_mats, _dbg_boxes])
	if _dbg:
		print("[cut] %s run#%d/%d %s fractured=%d/%d boxes=%d aabb %.2f -> %.2f%s" % [
			uuid.substr(0, 8), _dbg_seq, _apply_cuts_seq,
			"SERVER" if OS.has_feature("dedicated_server") else "client",
			_dbg_pending, fractures.size(), _dbg_boxes,
			_dbg_before.x, _piece_aabb().size.x,
			"  <-- STILL WHOLE" if _dbg_pending > 0 and _dbg_boxes == 0 else ""])
	_build_mesh_collider()
	_refresh_mass()
	# Hand the piece back to physics — server only, and never against the server's own culler: a
	# client replica stays frozen (its pose comes from replication), and a body the settle-culler
	# parked far from every player must stay parked. This is the moment the new centre of mass takes
	# effect, which is what topples the two halves off each other.
	if OS.has_feature("dedicated_server") and not get_meta("_culled_frozen", false):
		freeze = false
	RockDebug.t_end("rock:cuts", _cut_tok)
	_apply_cuts_running = false
	if _apply_cuts_dirty:
		_apply_cuts_dirty = false
		await _apply_cuts()

## How many rocks may carve their geometry in the SAME frame. A carve is one CSG bake plus one
## QuickHull, and both are main-thread; what matters is not their total cost but how many land
## together.
##
## ONE, measured. The bake is the expensive half — a 19-piece zone re-entry showed rock:hull at
## 116 ms for 47 calls (2.45 ms each, nothing) while the frames it landed in ran 131-147 ms, so a
## bake is ~55-60 ms on a multi-cut rock. At two per frame that is a hitch every time, and the log
## showed exactly that: six frames over 100 ms in the burst, plus the odd 110-134 ms frame during
## ordinary mining. One per frame keeps a carving frame near 75 ms, under the hitch threshold.
##
## What it costs: the second replay of a live cut — the half that spawns off the one you keep —
## waits a frame, ~20 ms. The two halves already appear at different instants, so this is not
## something a player can see. A zone re-entry spreads over ~19 frames (~370 ms) instead of ~10,
## and nobody is watching a particular piece while a field streams back in.
const MAX_REPLAYS_PER_FRAME := 1

## Admission gate shared by every rock, on BOTH sides: the client re-enters a zone and its whole
## field replays at once, and the server has the same burst restoring a zone from the database.
## Static because the budget is per FRAME across all rocks, not per rock.
static var _replay_frame: int = -1
static var _replay_count: int = 0

## Take a carve slot for this frame, or report that the frame is full. Total work is unchanged —
## only its distribution: no frame carries more carves than a normal two-piece cut already does.
static func _claim_replay_slot() -> bool:
	var frame: int = Engine.get_process_frames()
	if frame != _replay_frame:
		_replay_frame = frame
		_replay_count = 0
	if _replay_count >= MAX_REPLAYS_PER_FRAME:
		return false
	_replay_count += 1
	return true


## True while `fractures` records cuts that the geometry does not show yet — a rock restored from the
## database, or a half just split off, always arrives WHOLE and replays them in _apply_cuts.
func _has_pending_cuts() -> bool:
	for frac in fractures:
		if frac.get("fractured", false):
			return true
	return false

## We frature the rock
## Apply ONE cut. The caller (_rebuild_fracture_all) owns saving and restoring the rock's pose —
## doing it here as well would nest two savers and lose the real original — and it owns waiting for
## the bake, which happens once for the whole batch.
func _rebuild_fracture(fracture: Dictionary) -> void:
	# we set the position when the cut is processed
	var cut_position = fracture.get("cut_position", {"x": 0.0, "y": 0.0, "z": 0.0})
	position = Vector3(cut_position["x"], cut_position["y"], cut_position["z"])
	var cut_rotation = fracture.get("cut_rotation", {"x": 0.0, "y": 0.0, "z": 0.0})
	rotation = Vector3(cut_rotation["x"], cut_rotation["y"], cut_rotation["z"])

	# We cut the rock. Guaranteed to be a CSGMesh3D here: _apply_cuts restores the CSG backend
	# before the replay starts.
	_ensure_csg_backend(true)
	_mesh_node().add_child(_make_cut_box(fracture))

## Build the CSG box that subtracts one half of the rock along a fracture plane.
## plane_offset = dot(normal, point_on_plane) in rock-local space — already bakes in
## the mesh-centre correction, so no extra shift is needed here.
func _make_cut_box(frac: Dictionary) -> CSGBox3D:
	var aabbBox: AABB = _source_mesh().get_aabb()
	var box := CSGBox3D.new()
	box.size = Vector3(2.0 * aabbBox.size.x, 2.0 * aabbBox.size.y, 2.0 * aabbBox.size.z)
	var rx: float = frac.get("rotation_x", 0.0)
	var ry: float = frac.get("rotation_y", 0.0)
	var rz: float = frac.get("rotation_z", 0.0)
	# Align the box's local X axis with the fault normal so translate_object_local
	# moves the box along the normal direction.
	box.rotation = Vector3(deg_to_rad(rx), deg_to_rad(ry), deg_to_rad(rz))
	var offset: float = frac.get("plane_offset", 0.0)
	# keep_side 1 = keep +normal half -> remove -normal half (box centre below the plane).
	# keep_side 2 = keep -normal half -> remove +normal half (box centre above the plane).
	var box_x: float
	if int(frac.get("keep_side", 1)) == 1:
		box_x = offset - aabbBox.size.x
	else:
		box_x = offset + aabbBox.size.x
	box.translate_object_local(Vector3(box_x, 0.0, 0.0))
	box.operation = CSGShape3D.OPERATION_SUBTRACTION
	# In Godot's CSG the faces a brush carves inherit THAT brush's material, which is how the cut
	# face gets the ore look while the untouched skin keeps the plain one. Only meaningful where
	# there is something to render — the dedicated server builds no materials at all.
	if not OS.has_feature("dedicated_server"):
		box.material = _make_inner_material()
	return box



## Per-piece ore purity (0..1) = how much of the rock is actually mineralised. Derived from
## `ore_seed`, so every client agrees without replicating it, and so every piece cut off the same
## rock shares it — cutting REVEALS ore, it never re-rolls it. MiningZone picks the seed so this
## lands near the zone's `richness` target. Deliberately NOT visible from the outside: only a cut
## face shows the mineral (see _make_exterior_material).
func ore_richness() -> float:
	var s: String = ore_seed if ore_seed != "" else uuid
	if s == "":
		return 0.5
	return float(absi(s.hash()) % 1000) / 1000.0

## The piece's bounding box, in MESH-LOCAL space (so unscaled — see _mesh_scale). Read from the
## CSGMesh3D NODE, which is the CSG RESULT: it shrinks with every subtraction box a cut adds, while
## `mesh.get_aabb()` would keep reporting the whole uncut rock forever. Falls back to the source
## mesh while the CSG has not been baked yet (the first frames after the node enters the tree).
func _piece_aabb() -> AABB:
	var mesh_node := _mesh_node()
	if mesh_node == null:
		return AABB()
	var box: AABB = mesh_node.get_aabb()
	if box.size.x > 0.0 and box.size.y > 0.0 and box.size.z > 0.0:
		return box
	var src: Mesh = _source_mesh()
	return src.get_aabb() if src != null else AABB()

## Uniform scale the rock mesh carries in its scene: x1 small, x1.2 medium, x2 large (see
## rock_mining_{sm,md,lg}.tscn — the three variants share ONE mesh and differ only by this). Every
## AABB above is node-local, so it has to be scaled to reach real metres.
func _mesh_scale() -> float:
	var mesh_node := _mesh_node()
	return mesh_node.scale.x if mesh_node != null else 1.0

## A point given in BODY-local space, expressed in MESH-local space — the frame every fracture plane
## lives in. The two are NOT the same: the CSGMesh3D carries the variant's scale (x1 sm, x1.2 md, x2
## lg), while `plane_offset` was measured on the UNSCALED source mesh. MiningTool aims with
## rock.to_local(hit), i.e. body-local, so on a medium or large rock the fault test was off by that
## factor — the accepted aim point sat nowhere near the crack line the shader draws.
func _to_mesh_local(body_local: Vector3) -> Vector3:
	var mesh_node := _mesh_node()
	if mesh_node == null:
		return body_local
	return mesh_node.transform.affine_inverse() * body_local

## Longest side (metres) of the piece as it stands — the size half of the breakable test.
func longest_side() -> float:
	var box: AABB = _piece_aabb()
	return maxf(box.size.x, maxf(box.size.y, box.size.z)) * _mesh_scale()

## Volume (m3) of the piece AS IT STANDS, in real world units.
func get_volume() -> float:
	var box: AABB = _piece_aabb()
	var s: float = _mesh_scale()
	return box.size.x * box.size.y * box.size.z * s * s * s * VOLUME_FILL

## Ore volume (m3) this piece holds — what the depot pays for. Zero for an inert mineral
## (basalt / granite / sandstone yield nothing, the piece is barren rock through and through).
func get_ore_volume() -> float:
	if mineral == null or mineral.is_inert:
		return 0.0
	return get_volume() * ore_richness()

## Volume (m3) of the barren host rock (the gangue) around the ore — the rest of the piece.
func get_gangue_volume() -> float:
	return get_volume() - get_ore_volume()

## The piece's REAL mass (kg): each of its two materials weighed on its OWN volume — the mineral
## over the ore volume, the host rock over the gangue volume. This is the only mass a rock ever has;
## the `mass` set on the RigidBody in rock_mining_{sm,md,lg}.tscn is a placeholder that _refresh_mass
## overwrites at spawn. Every input is deterministic and replicated (mineral_id, ore_seed,
## inert_density, geometry), so server and clients reach the same number on their own.
func real_mass() -> float:
	var ore_density: float = 0.0
	if mineral != null and not mineral.is_inert:
		ore_density = mineral.density_kg_m3
	return get_ore_volume() * ore_density + get_gangue_volume() * inert_density

## Can a player pick this piece up? Pure handling: small enough AND light enough, measured on the
## CURRENT geometry, so a piece qualifies only once it has actually been cut down to size. Every
## input is deterministic and replicated, so the server (which decides) and the client agree.
func can_be_carried() -> bool:
	return longest_side() <= CARRY_MAX_SIZE and real_mass() <= CARRY_MAX_MASS

## Carry contract. PlayerServer asks this twice — once to decide whether to show the "Carry [E]"
## prompt (_compute_carry_prompt) and again to authorise the actual grab (server_action_received) —
## so this one override gates both. Without it the question fell through to PropSync.interact(),
## which only answers "is somebody else already holding it?", and every rock offered the prompt.
func interact(_interactor: Node = null) -> bool:
	return can_be_carried() and not carried

## Apply the real mass to the rigid body. Runs on BOTH sides — at spawn (_ready), whenever a
## replicated input lands (apply_prop_data) and after every cut (check_rock) — so a broken-off half
## carries its own share instead of the whole rock's. The server also publishes it as `weight`, for
## Horizon and for whatever reads the prop's mass off the network rather than off the body.
func _refresh_mass() -> void:
	mass = maxf(1.0, real_mass())
	if OS.has_feature("dedicated_server"):
		server_prop_update({"weight": mass})

#####################################################################
# Client part
#####################################################################

func _client_ready() -> void:
	# DIAGNOSIS (--rocks-hidden): keep the body, the collider and the whole spawn path, draw nothing.
	# Whatever FPS comes back with this flag is the RENDERING half of the cost; whatever does not is
	# the spawn half.
	var mesh_node := _mesh_node()
	if RockDebug.hidden and mesh_node != null:
		mesh_node.visible = false

	# Paint the rock with its OWN mineral, breakable or not: a rock too small to fracture still has
	# to show the right host-rock texture. _make_exterior_material() only draws the crack line when
	# an un-fractured plane exists, so a non-breakable rock simply gets no groove.
	_show_faults()
	# Created already under a vehicle (piece loaded before we arrived): ride it (KINEMATIC).
	PropNet.apply_ride_freeze_mode(self)

## Show the not-yet-fractured fault as a black vein (a thin slice through the rock)
## at its cut plane, so faults are visible before perforating.
## Signature of the look the rock currently WEARS. Same idea as _applied_cut_signature, and for the
## same reason: apply_prop_data re-runs _client_ready on every replicated change, and the ore /
## fracture channels tick several times a second per rock — measured at 310 repaints for 48 rocks in
## one 4 s window. Each of those allocated a fresh ShaderMaterial for a look identical to the one
## already on the mesh, and handed the renderer a brand new material to set up.
var _painted_signature: String = ""


## Everything the exterior material is built FROM. Only these move the look: the two minerals name
## every texture and finish, the seed places the ore field, and the still-UN-fractured planes are
## the crack lines the shader draws (a plane that has been cut no longer draws one). The groove /
## crack tuning is @export, so it cannot change on a live rock.
func _paint_signature() -> String:
	var parts := PackedStringArray()
	parts.append(str(mineral.id) if mineral != null else "")
	parts.append(str(host_rock.id) if host_rock != null else "")
	parts.append(ore_seed)
	for frac in fractures:
		if frac.get("fractured", false):
			continue
		var d: Dictionary = frac
		parts.append("%s,%s,%s,%s" % [
			d.get("rotation_x", 0.0), d.get("rotation_y", 0.0),
			d.get("rotation_z", 0.0), d.get("plane_offset", 0.0)])
	return "|".join(parts)


func _show_faults() -> void:
	# `rock:paint` on the [CPerf+] line. The x<n> count matters as much as the time — see
	# _painted_signature: a field that keeps repainting itself shows up as a hit count far above
	# the number of rocks.
	var _paint_tok := RockDebug.t()
	var signature := _paint_signature()
	if signature == _painted_signature:
		RockDebug.t_end("rock:paint", _paint_tok)
		return
	var mesh_node := _mesh_node()
	if mesh_node != null:
		# Clear the scene's static material_override and drive the SURFACE material instead. An
		# override outranks EVERY surface of the instance, including the faces the subtraction brush
		# carves, so leaving one in place repaints the cut face with the ore-suppressing exterior
		# material — the rock then reads as plain stone however deep you cut it.
		mesh_node.material_override = null
		_set_surface_material(_make_exterior_material())
		_painted_signature = signature
	RockDebug.t_end("rock:paint", _paint_tok)

## Exterior (uncut surface): NO ore at all — just the plain rock plus the neutral fault crack
## line. The mineral is revealed ONLY on the cut faces, so the player must fracture to see what
## the rock holds inside (Kainan/DDURIEUX).
func _make_exterior_material() -> ShaderMaterial:
	var mat := _make_rock_material(0.7, 14.0, true)
	# Suppress ore on the exterior: an ore_threshold >= 1 makes the shader's smoothstep return
	# 0 everywhere (the fbm value never reaches 1), and zero emission kills any metal glint —
	# the surface stays neutral rock so nothing about the mineral leaks before the first cut.
	mat.set_shader_parameter("ore_threshold", 1.0)
	mat.set_shader_parameter("ore_emission", 0.0)
	return mat

## Inner (cut face): where the mineral is actually revealed. The threshold is interpolated by the
## piece's own purity — a rich rock crosses it over a wide band and shows broad veins, a poor one
## barely at all — and ORE_SCALE keeps the pattern coarse enough to read at arm's length.
##
## The fault grooves are drawn here TOO. A fault is a plane through the whole piece, so the line it
## draws has to run across the cut face as well as around the skin: without it the crack stopped
## dead at the edge of the last cut and the next plane looked like it only reached half the rock.
## _make_rock_material skips already-fractured planes, so the face never re-draws the very cut that
## created it — only the faults still to come.
##
## This is the counterpart of _make_exterior_material, and the whole point of cutting: the pair
## exists so a player must fracture a rock to learn what it holds. Losing it makes every cut face
## look like plain stone.
func _make_inner_material() -> ShaderMaterial:
	return _make_rock_material(lerpf(ORE_T_POOR, ORE_T_RICH, ore_richness()), ORE_SCALE, true)

## Build a rock material. ore_threshold/ore_scale set the ore amount/size; with_grooves
## adds the neutral fault grooves (only the exterior surface shows them).
func _make_rock_material(ore_threshold_v: float, ore_scale_v: float, with_grooves: bool) -> ShaderMaterial:
	# DIAGNOSIS (--rocks-shared-mat): hand every rock the SAME material. Prices suspect 3 — the cost
	# of building one ShaderMaterial per rock, and the cost of every rock being its own un-batchable
	# draw call with its own pipeline specialization. Every rock then looks identical (no per-rock
	# ore field, no crack lines), so this is a measurement mode, not a shipping one.
	if RockDebug.shared_material:
		return _shared_debug_material()
	var _mat_tok := RockDebug.t()
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://assets/_universe/environment/terrain/rocks/rock_vein.gdshader")
	var _fallback_rock_tex := preload("res://assets/textures/grounds/rock/Rock029_2K_Color.jpg")
	# The exterior belongs to the HOST ROCK when one was replicated; otherwise it keeps coming from
	# the ore mineral's own rock_* fields (pre-host_rock_id behaviour). Relief and finish are read
	# ONLY from a real host rock: taking them from the ore mineral would repaint every existing rock
	# with gold's polish the day gold gets a normal map.
	var exterior: MineralDef = host_rock if host_rock != null else mineral
	var rock_tex: Texture2D = exterior.rock_albedo_tex if exterior != null and exterior.rock_albedo_tex != null else _fallback_rock_tex
	mat.set_shader_parameter("albedo_tex", rock_tex)
	mat.set_shader_parameter("tex_scale", exterior.rock_tex_scale if exterior != null else 1.0)
	mat.set_shader_parameter("rock_use_normal", host_rock != null and host_rock.rock_normal_tex != null)
	if host_rock != null:
		mat.set_shader_parameter("rock_normal_tex", host_rock.rock_normal_tex)
		mat.set_shader_parameter("rock_normal_strength", host_rock.rock_normal_strength)
		mat.set_shader_parameter("rock_roughness", host_rock.rock_roughness)
	# Ore LOOK (texture / colour / metalness) comes from the mineral; the ore FIELD
	# (amount, distribution) stays per-rock so fracture & purity behaviour is unchanged.
	_apply_mineral(mat)
	mat.set_shader_parameter("ore_scale", ore_scale_v)
	mat.set_shader_parameter("ore_threshold", ore_threshold_v)
	if mineral != null and mineral.is_inert:
		mat.set_shader_parameter("ore_threshold", 1.0)  # suppress ore veins on inert minerals
		mat.set_shader_parameter("ore_emission", 0.0)
	mat.set_shader_parameter("ore_softness", ORE_SOFTNESS)
	mat.set_shader_parameter("noise_offset", _ore_offset())  # per-rock ore distribution
	mat.set_shader_parameter("groove_width", groove_width)
	mat.set_shader_parameter("groove_color", groove_color)
	mat.set_shader_parameter("groove_strength", groove_strength)
	mat.set_shader_parameter("crack_warp_freq", crack_warp_freq)
	mat.set_shader_parameter("crack_warp_amp", crack_warp_amp)
	mat.set_shader_parameter("crack_width_var", crack_width_var)
	var normals: Array = []
	var offsets: Array = []
	if with_grooves:
		for frac in fractures:
			if frac.get("fractured", false):
				continue
			var rx: float = frac.get("rotation_x", 0.0)
			var ry: float = frac.get("rotation_y", 0.0)
			var rz: float = frac.get("rotation_z", 0.0)
			var n: Vector3 = Basis.from_euler(Vector3(deg_to_rad(rx), deg_to_rad(ry), deg_to_rad(rz))) * Vector3(1.0, 0.0, 0.0)
			normals.append(n)							   # fault plane normal (rock-local)
			offsets.append(frac.get("plane_offset", 0.0))  # already mesh-centre-corrected
	mat.set_shader_parameter("plane_count", normals.size())
	mat.set_shader_parameter("plane_normals", normals)
	mat.set_shader_parameter("plane_offsets", offsets)
	RockDebug.t_end("rock:material", _mat_tok)
	return mat


## DIAGNOSIS ONLY (--rocks-shared-mat): one material for the whole field, built once.
static var _debug_shared_material: ShaderMaterial = null

func _shared_debug_material() -> ShaderMaterial:
	if _debug_shared_material == null:
		_debug_shared_material = ShaderMaterial.new()
		_debug_shared_material.shader = preload("res://assets/_universe/environment/terrain/rocks/rock_vein.gdshader")
		_debug_shared_material.set_shader_parameter("albedo_tex",
			preload("res://assets/textures/grounds/rock/Rock029_2K_Color.jpg"))
		_debug_shared_material.set_shader_parameter("ore_threshold", 1.0)
		_debug_shared_material.set_shader_parameter("ore_emission", 0.0)
		_debug_shared_material.set_shader_parameter("plane_count", 0)
	return _debug_shared_material

## PropSync.client_channel_data_update applies the replicated transform and the reparent /
## carry-collision handling, then calls this with the full payload so the rock can apply its OWN
## (non-transform) fields. Replaces the old client_channel_data_update override.
func apply_prop_data(data: Dictionary) -> void:
	var run_ready: bool = false

	# The ore field derives from the seed and the look from the mineral, so either one arriving
	# means the material has to be rebuilt (run_ready). Both are set BEFORE the fracture handling
	# below, so the single _client_ready() at the end paints with the final values.
	if data.has("ore_seed"):
		var seed_value: String = str(data["ore_seed"])
		if seed_value != ore_seed:
			ore_seed = seed_value
			run_ready = true

	if data.has("mineral_id"):
		if _set_mineral(str(data["mineral_id"])):
			run_ready = true

	# Read BEFORE any mass work below: the bulk density mixes it with the mineral's own. A change
	# here is a mass change on its own, so it has to raise run_ready like every other input real_mass
	# reads — `inert_density` rides the 30 Hz channel 0 while `mineral_id` / `host_rock_id` ride the
	# 3 Hz channel 6, so a packet CAN carry the density and nothing else, and the body would then
	# keep weighing the old rock. It only looked safe because channel 0 usually also carries
	# `can_be_breakable`, which raises the flag by accident.
	if data.has("inert_density"):
		var density: float = float(data["inert_density"])
		if not is_equal_approx(density, inert_density):
			inert_density = density
			run_ready = true

	# AFTER inert_density on purpose: the host rock names the geology, so its own density is the
	# authority and the replicated number is only what a rock spawned before host rocks existed
	# (or by something that sends no id) has to go on. One id, one density — they cannot drift.
	if data.has("host_rock_id"):
		if _set_host_rock(str(data["host_rock_id"])):
			run_ready = true


	# `weight` is deliberately NOT applied here. The mass is DERIVED (real_mass) from inputs that
	# are all replicated and deterministic, so a client reaches the same number on its own; taking
	# the payload value instead would let a stale persisted weight override the live geometry.
	if data.has("can_be_breakable"):
		can_be_breakable = data["can_be_breakable"]
		run_ready = true

	if data.has("fractures"):
		fractures = data["fractures"]
		# sort by seq to have the fractures in the right order
		fractures.sort_custom(func(a, b): return a.get("seq", 0) < b.get("seq", 0))
		if not is_node_ready():
			await ready
			await get_tree().process_frame
		await _apply_cuts()
		# The geometry now matches the fracture history, so the server can finally judge the piece:
		# is it still breakable, and does it need its next crack plane? (See _server_ready.)
		if OS.has_feature("dedicated_server"):
			check_rock()
		run_ready = true

	# Rebuild the LOOK only where there is one to see. apply_prop_data also runs on the dedicated
	# server (server.gd replays the persisted object_data through PropSync), and building a
	# ShaderMaterial per rock there is pure waste at ~1000 rocks per field.
	if run_ready:
		# The mineral, the seed or the cut geometry moved: every one of them feeds real_mass.
		if is_node_ready():
			_refresh_mass()
		# Rebuild the LOOK only where there is one to see. apply_prop_data also runs on the
		# dedicated server (server.gd replays the persisted object_data through PropSync), and
		# building a ShaderMaterial per rock there is pure waste at ~1000 rocks per field.
		if not OS.has_feature("dedicated_server"):
			_client_ready()

## Resolve a replicated mineral_id ("gold", "basalt", …) to its MineralDef through MineralRegistry.
## Returns true when it actually changed, so the caller knows the material must be rebuilt. An
## unknown id is ignored (MineralRegistry already pushes a warning) rather than resetting to gold.
func _set_mineral(id: String) -> bool:
	if id == "" or not MineralRegistry.has_mineral(StringName(id)):
		return false
	var m: MineralDef = MineralRegistry.get_mineral(StringName(id))
	if m == mineral:
		return false
	mineral = m
	return true

## Resolve a replicated host_rock_id ("corundum_sapphire", "granite", …) to its MineralDef and take
## its density as the gangue's. Returns true when it changed, so the caller rebuilds the material.
## An empty or unknown id leaves the rock on whatever it already had rather than resetting it.
func _set_host_rock(id: String) -> bool:
	if id == "" or not MineralRegistry.has_mineral(StringName(id)):
		return false
	var m: MineralDef = MineralRegistry.get_mineral(StringName(id))
	if m == host_rock:
		return false
	host_rock = m
	inert_density = m.density_kg_m3
	return true


func _apply_mineral(mat: ShaderMaterial) -> void:
	if mineral != null:
		mat.set_shader_parameter("ore_use_texture", mineral.use_texture)
		mat.set_shader_parameter("ore_albedo_tex", mineral.albedo_tex)
		mat.set_shader_parameter("ore_normal_tex", mineral.normal_tex)
		mat.set_shader_parameter("ore_tex_scale", mineral.tex_scale)
		mat.set_shader_parameter("ore_normal_strength", mineral.normal_strength)
		mat.set_shader_parameter("ore_color", mineral.color)
		mat.set_shader_parameter("ore_metallic", mineral.metallic)
		mat.set_shader_parameter("ore_roughness", mineral.roughness)
		mat.set_shader_parameter("ore_emission", mineral.emission)
	else:
		mat.set_shader_parameter("ore_use_texture", false)
		mat.set_shader_parameter("ore_color", ORE_COLOR)
		mat.set_shader_parameter("ore_metallic", ORE_METALLIC)
		mat.set_shader_parameter("ore_roughness", ORE_ROUGHNESS)
		mat.set_shader_parameter("ore_emission", ORE_EMISSION)

func _ore_offset() -> Vector3:
	var s: String = ore_seed if ore_seed != "" else uuid   # pieces inherit the original seed
	return Vector3(
		float(absi((s + "x").hash()) % 100000) / 1000.0,
		float(absi((s + "y").hash()) % 100000) / 1000.0,
		float(absi((s + "z").hash()) % 100000) / 1000.0)

#####################################################################
# Server part
#####################################################################

## Server-side state update: forward to the PropSync component, which stamps the rock's uuid /
## type_name and emits it. Replaces the old GenericProp.server_send_properties_to_client().
func server_prop_update(data: Dictionary) -> void:
	var s := _prop_sync()
	if s != null:
		s.server_prop_update(data)

func _server_ready() -> void:
	# A rock with cuts still to replay is geometrically WHOLE right now: measuring it here would call
	# it breakable when it is not, and would generate its next crack plane from the uncut box. The
	# caller of _apply_cuts runs check_rock once the geometry is real.
	if not _has_pending_cuts():
		check_rock()
	# NOTE: per-frame replication AND the "settled rock stops ticking" sleep gate both live in the
	# PropSync child now (see PropSync._on_host_sleeping_state_changed) — ~1000 idle server_tick
	# callbacks otherwise dominate the step. Nothing to wire up here.
	# Remember the collider's layers so the proximity sweep (server) can restore them when a player
	# comes near and zero them when none is, dropping far rocks out of the physics broadphase.
	_coll_layer = collision_layer
	_coll_mask = collision_mask

## Server: called periodically by Server._refresh_rock_proximity. A settled rock keeps its collider
## only while a player is within range (so it stays walkable / hittable by the mining ray); when no
## player is near, its collider is removed from the broadphase entirely — the only thing that scales
## to a ~1000-rock field, since even a frozen-but-present body still costs per step. Force-freezes a
## settled body too, so disabling its collider can't let it fall (and as a backstop for any rock the
## sleep gate missed).
func server_update_proximity(near: bool) -> void:
	if not OS.has_feature("dedicated_server"):
		return
	if get_parent() is Player or get_parent() is Vehicle:
		return  # carried / bedded: collision is owned by the carry system, leave it alone
	if not freeze:
		if sleeping:
			freeze_mode = FREEZE_MODE_STATIC
			freeze = true   # settled: pin it so removing the collider can't drop it through the world
		else:
			return          # still falling/settling: keep full collision until it comes to rest
	if near:
		if _coll_disabled:
			collision_layer = _coll_layer
			collision_mask = _coll_mask
			_coll_disabled = false
	elif not _coll_disabled:
		collision_layer = 0
		collision_mask = 0
		_coll_disabled = true

func check_rock() -> void:
	# check if the rock can be breakable
	var _can_be_breakable: bool = true
	if fractures.size() > 0:
		if not _is_breakable_piece():
			_can_be_breakable = false
			
	can_be_breakable = _can_be_breakable
	server_prop_update({"can_be_breakable": can_be_breakable})
	_refresh_mass()
	if not _can_be_breakable:
		# no breakable, don't need to generate fracture plane
		return
		
	# Now, if the rock is breakable, create fracture plan if not exists
	var has_active_plane := false
	for frac in fractures:
		if not frac.get("fractured", false):
			has_active_plane = true
			break
	if not has_active_plane:
		_generate_fracture_plane()
		# TODO send fratures to client



## True while the piece is still worth cutting — which is exactly "while the player cannot carry it
## yet". A piece under BOTH carry limits (CARRY_MAX_SIZE and CARRY_MAX_MASS) can no longer be broken:
## there is nothing left to gain from cutting it, you just pick it up. Deriving breakability from
## carriability is what makes the loop self-closing: whatever the mineral's density, you keep
## splitting until the piece is liftable, and nothing has to be retuned when a denser mineral is
## added.
##
## Both measurements read the CSG result, so they really shrink with each cut, and both are identical
## on the server and on every client (same geometry, same replicated mineral / seed) without any
## extra replication.
func _is_breakable_piece() -> bool:
	return not can_be_carried()

# Generate the next fracture plane and append it to `fractures`. Computed from _piece_aabb(), the
# CSG RESULT — i.e. what is LEFT of the rock. Using the source mesh instead put every later plane in
# the frame of the whole rock, so from the second cut on it could land inside the half that had just
# been removed: a crack line drawn in empty space, and a cut that amputated nothing.
func _generate_fracture_plane() -> void:
	var entry := _compute_fracture_plane(_piece_aabb())
	if entry.is_empty():
		# to prevent problems
		can_be_breakable = false
		return
	entry["seq"] = fractures.size()
	fractures.append(entry)
	server_prop_update({"fractures": fractures})



func _compute_fracture_plane(aabb: AABB) -> Dictionary:

	# Find the largest side of the AABB to cut it
	var sizes := [aabb.size.x, aabb.size.y, aabb.size.z]
	var largest_axis := -1
	var largest_size := 0.0
	for i in 3:
		if sizes[i] > largest_size:
			largest_size = sizes[i]
			largest_axis = i
	if largest_axis < 0:
		printerr("RockMining: _compute_fracture_plane() failed to find a largest axis for AABB ", aabb)
		return {}
	# The fracture-plane normal is, BY CONVENTION, `Basis.from_euler(rot) * X` — every
	# consumer (groove shader, cut box, is_on_fault, server_perforate, _estimate_half_aabb)
	# reconstructs it that way. So bake the largest-axis choice into the rotation: a base
	# rotation that maps local +X onto the chosen axis, then the small perturbation. This
	# keeps the cut perpendicular to the longest dimension AND keeps the stored plane_offset
	# measured along the SAME normal the shader draws with — otherwise the crack plane misses
	# the geometry (no visible crack, cut in the wrong place) whenever Y or Z is longest.
	var max_angle_amplitude := 5.0  # degrees
	var base_rot := Vector3.ZERO
	if largest_axis == 1:
		base_rot = Vector3(0.0, 0.0, 90.0)    # +X -> +Y
	elif largest_axis == 2:
		base_rot = Vector3(0.0, -90.0, 0.0)   # +X -> +Z
	var rx := base_rot.x + randf_range(-max_angle_amplitude, max_angle_amplitude)
	var ry := base_rot.y + randf_range(-max_angle_amplitude, max_angle_amplitude)
	var rz := base_rot.z + randf_range(-max_angle_amplitude, max_angle_amplitude)
	var normal: Vector3 = Basis.from_euler(Vector3(deg_to_rad(rx), deg_to_rad(ry), deg_to_rad(rz))) * Vector3(1.0, 0.0, 0.0)
	# Perturb ±20 % of the half-size along the (now largest-axis-aligned) normal so cuts are
	# never exactly centred, while staying well inside the rock.
	var center_point: Vector3 = aabb.get_center() + normal * randf_range(-0.2, 0.2) * (largest_size * 0.5)
	var plane_offset: float = normal.dot(center_point)
	return {
		"fractured": false,
		"rotation_x": rx,
		"rotation_y": ry,
		"rotation_z": rz,
		"plane_offset": plane_offset,
		"keep_side": 1,
	}

## True if a rock-local point lies on the active (un-fractured) crack plane. Uses the SAME
## test as server_perforate (same normal, same plane_offset, same FAULT_HIT_THRESHOLD), so the
## client only starts a real perforation where the server will actually cut. MiningTool calls
## this in _capture_target(); without it _target_on_fault stays false, the tool only plays the
## off-fault "rejected" jab, and nothing is ever sent to the server.
## How far from the mathematical plane an aim point still counts as "on the crack": the base
## tolerance PLUS however far the shader's warp can push the VISIBLE crack off that plane. Without
## the second term the player would aim at the line they can see and be rejected wherever the
## meander happens to wander away from the plane.
func _fault_tolerance() -> float:
	return FAULT_HIT_THRESHOLD + absf(crack_warp_amp)

func is_on_fault(hit_local: Vector3) -> bool:
	var hit_mesh: Vector3 = _to_mesh_local(hit_local)
	var tolerance: float = _fault_tolerance()
	for frac in fractures:
		if frac.get("fractured", false):
			continue
		var rx: float = frac.get("rotation_x", 0.0)
		var ry: float = frac.get("rotation_y", 0.0)
		var rz: float = frac.get("rotation_z", 0.0)
		var n: Vector3 = Basis.from_euler(Vector3(deg_to_rad(rx), deg_to_rad(ry), deg_to_rad(rz))) * Vector3(1.0, 0.0, 0.0)
		if absf(n.dot(hit_mesh) - frac.get("plane_offset", 0.0)) <= tolerance:
			return true
	return false

## Server: cut the rock along its active (last un-fractured) crack plane.
## `hit_local` = rock-local aim point; the player keeps the half their hit is on.
## `push_dir_local` = drill direction, kept in the signature (PlayerServer sends it) but NOT applied:
## the two halves separate under their own new centres of mass, no scripted impulse.
func server_perforate(hit_local: Vector3, _push_dir_local: Vector3 = Vector3.ZERO) -> void:
	print("YOLO")
	if not OS.has_feature("dedicated_server"):
		return
	# Find the last un-fractured crack plane — only one can be active at a time.
	var cut_i := -1
	for i in fractures.size():
		if not fractures[i].get("fractured", false):
			cut_i = i
	if cut_i < 0:
		print("[mining] perforate %s rejected: no active crack plane" % uuid)
		return   # no active crack plane; rock is fully fractured
	var frac: Dictionary = fractures[cut_i]
	# The aim point arrives in BODY-local space (MiningTool sends rock.to_local(hit)); every plane
	# lives in MESH-local space. Same conversion is_on_fault does, so client and server agree.
	var hit_mesh: Vector3 = _to_mesh_local(hit_local)
	var rx: float = frac.get("rotation_x", 0.0)
	var ry: float = frac.get("rotation_y", 0.0)
	var rz: float = frac.get("rotation_z", 0.0)
	var n_local: Vector3 = Basis.from_euler(Vector3(deg_to_rad(rx), deg_to_rad(ry), deg_to_rad(rz))) * Vector3(1.0, 0.0, 0.0)
	var plane_offset: float = frac.get("plane_offset", 0.0)
	var hit_dist: float = absf(n_local.dot(hit_mesh) - plane_offset)
	if hit_dist > _fault_tolerance():
		print("[mining] perforate %s rejected: hit %.3f from crack plane (max %.3f)" % [uuid, hit_dist, _fault_tolerance()])
		return   # aim point not close enough to the crack; no cut
	# The player keeps the half their hit point is on.
	var keep_side: int = 1 if n_local.dot(hit_mesh) >= plane_offset else 2
	var side2_uuid: String = UUID_UTIL.v4()
	frac["fractured"] = true
	frac["keep_side"] = keep_side
	frac["side2_uuid"] = side2_uuid
	frac["cut_position"] = {"x": position.x, "y": position.y, "z": position.z}
	frac["cut_rotation"] = {"x": rotation.x, "y": rotation.y, "z": rotation.z}
	server_prop_update({"fractures": fractures})
	# The other half spawns FIRST, at our exact transform and with physics off, so it is already
	# there (and inert) while both pieces amputate their complementary block. It is created BEFORE
	# check_rock() on purpose: check_rock appends the NEXT crack plane for OUR geometry, and the
	# other half has different geometry — it computes its own once its cut is applied.
	_server_create_side2_rock(cut_i)
	# Our own amputation. _apply_cuts holds physics off while the shape, the hull and the centre of
	# mass all change, then hands the piece back to Jolt: the new centre of mass is what makes the
	# two halves topple off each other and settle to sleep, with no scripted impulse.
	await _apply_cuts()
	print("[mining] perforate %s CUT plane %d (keep_side %d) -> side2 %s"
			% [uuid, cut_i, keep_side, side2_uuid])
	check_rock()
	# TEMPORARY (mining debug): size + mass of BOTH halves. Not awaited — it polls for the other
	# half, which does not exist yet at this point.
	_debug_print_halves(side2_uuid)

## TEMPORARY (mining debug): print the longest side and the real mass of the TWO pieces the cut just
## produced, server-side. Ours is measured straight away; the other half has to be looked up by uuid
## in the "miningrock" group and may only be measured once its OWN cut replay has finished — it
## spawns WHOLE and amputates a few frames later, so reading it any earlier reports the size of the
## uncut rock.
func _debug_print_halves(side2_uuid: String) -> void:
	print("[mining] halves %s | kept  %s: %.2f m, %.0f kg (carriable=%s breakable=%s)" % [
			uuid.substr(0, 8), uuid.substr(0, 8), longest_side(), real_mass(),
			can_be_carried(), can_be_breakable])
	var other: RockMining = null
	var settled: bool = false
	# ~2 s at 60 Hz. The spawn is local (network_orchestrator creates the body on this server too),
	# but the CSG replay behind it takes several frames.
	for _i in 120:
		if other == null or not is_instance_valid(other):
			other = null
			for node in get_tree().get_nodes_in_group("miningrock"):
				if node is RockMining and (node as RockMining).uuid == side2_uuid:
					other = node as RockMining
					break
		# A finished replay = one that has run (signature recorded) and is not running now.
		if other != null and not other._apply_cuts_running and other._applied_cut_signature != "":
			settled = true
			break
		await get_tree().process_frame
	if other == null or not is_instance_valid(other):
		print("[mining] halves %s | side2 %s: not found server-side" % [uuid.substr(0, 8), side2_uuid.substr(0, 8)])
		return
	print("[mining] halves %s | side2 %s: %.2f m, %.0f kg (carriable=%s breakable=%s)%s" % [
			uuid.substr(0, 8), side2_uuid.substr(0, 8), other.longest_side(), other.real_mass(),
			other.can_be_carried(), other.can_be_breakable,
			"" if settled else "  <-- cut replay NOT finished, size is the uncut rock"])

## The replicated scene path (registry key, no res:// prefix) of THIS rock variant, so a broken-off
## half spawns the SAME scene (small / medium / large) instead of a hardcoded one.
func _scene_name() -> String:
	if scene_file_path != "":
		return scene_file_path.trim_prefix("res://")
	return "scenes/_universe/environment/terrain/rocks/rock_mining_sm.tscn"

## Server: spawn the complementary half as its own networked rock. It inherits the WHOLE fracture
## history — so it shows the same crack lines and can be split again — except that the plane we just
## cut is flipped to the opposite `keep_side`, which makes its subtraction box remove OUR half
## instead of its own. The two pieces are therefore exact complements of the same rock.
func _server_create_side2_rock(cut_index: int) -> void:
	var side2_uuid: String = str(fractures[cut_index].get("side2_uuid", ""))
	if side2_uuid == "":
		printerr("RockMining: no side2_uuid on the cut plane, cannot spawn the other half")
		return
	var side2_fractures: Array = []
	for i in fractures.size():
		var f: Dictionary = (fractures[i] as Dictionary).duplicate(true)
		if i == cut_index:
			f["keep_side"] = 2 if int(f.get("keep_side", 1)) == 1 else 1
			f["side2_uuid"] = uuid  # the half it was split from is US
		side2_fractures.append(f)
	# EXACTLY where we are, not nudged: the two pieces are complements of one rock, so they must
	# start in the same frame. They separate on their own once _apply_cuts hands them back to
	# physics with their new hulls and centres of mass.
	# TEMPORARY (cut diagnosis): what we PUT ON THE WIRE for the other half. Paired with the
	# "[cut]   raw" line the receiving side prints, this says whether the flag leaves correct and
	# arrives wrong (Horizon's problem, another repo) or leaves wrong already (ours).
	print("[cut] SEND side2 %s flags=%s keep=%s" % [
		side2_uuid.substr(0, 8),
		side2_fractures.map(func(f): return (f as Dictionary).get("fractured", "<absent>")),
		side2_fractures.map(func(f): return (f as Dictionary).get("keep_side", "<absent>"))])
	NetworkOrchestrator.spawn_prop_authoritative({
		"type": "miningrock",
		"uuid": side2_uuid,
		"position": {"x": position.x, "y": position.y, "z": position.z},
		"rotation": {"x": rotation.x, "y": rotation.y, "z": rotation.z},
		"scenename": _scene_name(),
		# DERIVED from the tree, never declared: the frame our own `position` is expressed in is the
		# only one the new piece may be published under (see PropNet.server_tick).
		"parent_id": PropSpawn.parent_frame_uuid(self),
		"fractures": side2_fractures,
		# Inherit the ore field AND the two materials, so the half is the same rock, not a fresh
		# default-gold one: same seed -> same purity and same ore pattern across the cut.
		"ore_seed": ore_seed if ore_seed != "" else uuid,
		"mineral_id": str(mineral.id) if mineral != null else "",
		"host_rock_id": str(host_rock.id) if host_rock != null else "",
		"inert_density": inert_density,
	})
	# print("[mining] perforate %s CUT along plane %d (keep_side %d) -> %d fracture(s), breakable=%s" % [uuid, cut_i, keep_side, fractures.size(), can_be_breakable])
