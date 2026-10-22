class_name MovingPart
extends ToggledPart

## A door or a drawer: open, its leaf (a mesh of the model, the parent by default) turns about its own
## origin -- the hinge -- and/or slides in its own frame. The same motion runs on the server and the
## clients: what the leaf carries (a door's body) blocks the way where the door stands.
##
## It opens as far as it is set to, or less: the leaf's bodies are swept along the opening and it stops
## short of the first wall or piece of furniture they would cut into (free_reach). The same scene gives
## the same answer on the server and every client; players and loose props never stop it, nor does the
## terrain, which only the server has (PlanetTerrain.COLLISION_GROUP): there it held a container's door
## shut where the ground rose before it, while every client drew it open -- an invisible wall in the
## doorway of the NPCs' homes (playtest 2026-10-22).

## Opened by the server for an NPC living in its home (SpawnBuilding.server_open_for_npc): the door it
## goes out by -- an NPC never opens one itself.
@export var opens_for_npc: bool = false
## Anyone may shut it while it stands open, not only who lives there (opening stays theirs): a home's
## door left open on a walkway barred the way to everyone else (playtest 2026-10-22). The container's
## front doors.
@export var anyone_may_shut: bool = false
## The node that moves: the door leaf or the drawer.
@export var leaf_path: NodePath = ^".."
## Hinge axis, in the leaf's own frame (a door: up).
@export var hinge_axis: Vector3 = Vector3.UP
## Angle (degrees) the leaf turns by when open, about [member hinge_axis]. 0 for a drawer.
@export_range(-180.0, 180.0, 1.0) var open_angle_deg: float = 0.0
## Offset (m) the leaf slides by when open, in its own frame. Zero for a door.
@export var open_slide: Vector3 = Vector3.ZERO
## Time (s) to open or close it fully.
@export_range(0.05, 3.0, 0.05) var duration_s: float = 0.6
## A latch that turns before the leaf moves (a container door's handle), the leaf waiting for it; empty
## for none. It turns about its own origin, by [member latch_angle_deg] about [member latch_axis].
@export var latch_path: NodePath
## The latch's axis, in its own frame.
@export var latch_axis: Vector3 = Vector3.FORWARD
## Angle (degrees) the latch turns by before the leaf opens.
@export_range(-180.0, 180.0, 1.0) var latch_angle_deg: float = -90.0
## Share of the motion the latch takes, at the start of an opening (the end of a closing).
@export_range(0.0, 0.9, 0.05) var latch_share: float = 0.3
## Heard as it opens (a live change, not its state on arrival). Empty: silent.
@export var sfx_open: AudioStream
## Heard as it closes.
@export var sfx_close: AudioStream
## Seconds after the closing starts that its sound plays: 0 at once (a drawer), the time the leaf takes
## to swing shut for a door that slams.
@export_range(0.0, 3.0, 0.05) var sfx_close_delay_s: float = 0.0
## Loudness (dB) of those sounds at 2 m.
@export_range(-40.0, 12.0, 0.5) var sfx_db: float = -6.0

## Degrees between two poses tried while sweeping a door's opening.
const SWEEP_STEP_DEG := 3.0
## Metres between two poses tried while sweeping a drawer's.
const SWEEP_STEP_M := 0.02
## What stops a leaf: the world's solids (walls, furniture), never a player or a loose prop.
const SWEEP_MASK := 1 << (Globals.LAYER_WORLD - 1)

var _leaf: Node3D
var _rest: Transform3D
var _latch: Node3D
var _latch_rest: Transform3D
## How far open it is shown: 0 shut, 1 open.
var _open: float = 0.0
var _tween: Tween


func _ready() -> void:
	super()
	_leaf = get_node_or_null(leaf_path) as Node3D
	if _leaf != null:
		_rest = _leaf.transform
	_latch = get_node_or_null(latch_path) as Node3D if not latch_path.is_empty() else null
	if _latch != null:
		_latch_rest = _latch.transform
	# The building's state can be shown before the part is in the tree (the state arrives before the
	# building is placed): the leaf was not known then, so it takes that state now.
	if _leaf != null and is_on:
		_set_open(_open_target())


## Who may use it: its occupant, and anyone at all to shut it while it is open (anyone_may_shut).
func refusal(player: Node) -> String:
	if anyone_may_shut and is_on:
		return ""
	return super(player)


## SERVER: as asked for its occupant; anyone else may only shut it (anyone_may_shut), whatever they ask.
func server_use(player: Node, data: Dictionary) -> void:
	if anyone_may_shut and super.refusal(player) != "":
		data = {"on": false}
	super(player, data)


func _play(stream: AudioStream) -> void:
	Sfx3D.play_pitched(_leaf, stream, sfx_db, 2.0, 15.0, Sfx3D.Attenuation.VERY_SHORT, randf_range(0.95, 1.05))


## The leaf's pose [param t] of the way open (0 shut, 1 open), from its shut pose [param rest].
static func pose(rest: Transform3D, axis: Vector3, angle_deg: float, slide: Vector3, t: float) -> Transform3D:
	var basis: Basis = rest.basis
	if angle_deg != 0.0:
		basis = basis * Basis(axis.normalized(), deg_to_rad(angle_deg) * t)
	return Transform3D(basis, rest.origin + rest.basis * (slide * t))


func _show(on: bool, animate: bool) -> void:
	if _leaf == null:
		return
	var target: float = _open_target() if on else 0.0
	if _tween != null:
		_tween.kill()
	if not animate or not is_inside_tree():
		_set_open(target)
		return
	if not GameOrchestrator.is_server():
		if on or sfx_close_delay_s <= 0.0:
			_play(sfx_open if on else sfx_close)
		else:
			get_tree().create_timer(sfx_close_delay_s).timeout.connect(func() -> void:
				if is_instance_valid(self) and not is_on:  # reopened meanwhile: no slam
					_play(sfx_close))
	_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_method(_set_open, _open, target, duration_s * absf(target - _open))


## How far the latch ([0]) and the leaf ([1]) are at [param t] of the motion, the latch first over
## [param share] of it. Pure, for the tests.
static func phases(t: float, share: float) -> Vector2:
	if share <= 0.0:
		return Vector2(t, t)
	return Vector2(clampf(t / share, 0.0, 1.0), clampf((t - share) / (1.0 - share), 0.0, 1.0))


## How far the motion goes when open (0..1): all the way unless something stands in the leaf's way.
## With a latch, the latch still turns all the way first.
func _open_target() -> float:
	var share: float = latch_share if _latch != null else 0.0
	return share + (1.0 - share) * free_reach()


## How far (0..1) the leaf may open before one of its bodies would cut into a solid of the world: the
## pose before the first one that does. Neither the piece of furniture it belongs to counts (_own_solids:
## the wardrobe and its other door, the container and its other leaf) nor what touches it shut.
func free_reach() -> float:
	var shapes: Array[CollisionShape3D] = _leaf_shapes()
	if shapes.is_empty() or not is_inside_tree():
		return 1.0
	var steps: int = maxi(1, ceili(maxf(absf(open_angle_deg) / SWEEP_STEP_DEG, open_slide.length() / SWEEP_STEP_M)))
	var cast := ShapeCast3D.new()
	cast.enabled = false
	cast.top_level = true
	cast.target_position = Vector3.ZERO  # no motion: what the shape overlaps where it stands
	cast.collision_mask = SWEEP_MASK
	cast.max_results = 8
	add_child(cast)
	for body in _own_solids():
		cast.add_exception(body)
	var parent := _leaf.get_parent_node_3d()
	var frame: Transform3D = parent.global_transform if parent != null else Transform3D.IDENTITY
	var on_leaf: Array[Transform3D] = []
	for shape in shapes:
		on_leaf.append(_leaf.global_transform.affine_inverse() * shape.global_transform)
	for i in shapes.size():  # touching it shut: where it hangs, not in its way
		_overlaps(cast, shapes[i], frame * _rest * on_leaf[i], true)
	var reach: float = 1.0
	for step in range(1, steps + 1):
		var leaf_at: Transform3D = frame * pose(_rest, hinge_axis, open_angle_deg, open_slide, float(step) / steps)
		var blocked: bool = false
		for i in shapes.size():
			blocked = blocked or _overlaps(cast, shapes[i], leaf_at * on_leaf[i], false)
		if blocked:
			reach = float(step - 1) / steps
			break
	remove_child(cast)
	cast.free()
	return reach


## The solids of the piece of furniture the part belongs to -- the first one above it and everything in
## it: a double door's leaves meet edge to edge, a container's doors swing out of its own frame.
func _own_solids() -> Array[CollisionObject3D]:
	var out: Array[CollisionObject3D] = []
	var node: Node = get_parent()
	while node != null and not (node is CollisionObject3D and not (node is Area3D)):
		node = node.get_parent()
	if node == null:
		node = get_parent()  # loose (a test): its leaf's own bodies
	else:
		out.append(node as CollisionObject3D)
	for body in node.find_children("*", "CollisionObject3D", true, false):
		if not (body is Area3D):
			out.append(body as CollisionObject3D)
	return out


## The shapes of the leaf's own bodies (a door's DoorBody), which the sweep moves.
func _leaf_shapes() -> Array[CollisionShape3D]:
	var out: Array[CollisionShape3D] = []
	if _leaf == null:
		return out
	for body in _leaf.get_children():
		if body is CollisionObject3D and not (body is Area3D):
			for child in body.get_children():
				if child is CollisionShape3D and (child as CollisionShape3D).shape != null \
						and not (child as CollisionShape3D).disabled:
					out.append(child)
	return out


## True when [param shape] at [param at] overlaps a solid [param cast] does not ignore -- never the
## terrain (PlanetTerrain.COLLISION_GROUP), which only the server has; with [param ignore_them], those
## solids are ignored from now on.
static func _overlaps(cast: ShapeCast3D, shape: CollisionShape3D, at: Transform3D, ignore_them: bool) -> bool:
	cast.shape = shape.shape
	cast.global_transform = at
	cast.force_shapecast_update()
	var blocked: bool = false
	for i in cast.get_collision_count():
		var hit := cast.get_collider(i) as CollisionObject3D
		if hit == null:
			continue
		if hit.is_in_group(PlanetTerrain.COLLISION_GROUP):
			cast.add_exception(hit)  # never counts: out of the way for good
			continue
		blocked = true
		if ignore_them:
			cast.add_exception(hit)
	return blocked


func _set_open(t: float) -> void:
	_open = t
	var share: float = latch_share if _latch != null else 0.0
	var at: Vector2 = phases(t, share)
	if _latch != null:
		_latch.transform = pose(_latch_rest, latch_axis, latch_angle_deg, Vector3.ZERO, at.x)
	_leaf.transform = pose(_rest, hinge_axis, open_angle_deg, open_slide, at.y)
