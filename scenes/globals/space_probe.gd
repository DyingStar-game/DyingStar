class_name SpaceProbe
extends RefCounted

## TEMPORARY validation (rebase plan, étape "multi-monde"). Before refactoring the server around
## SubViewport.own_world_3d (one physics world per planet, each planet at ITS origin), prove the
## mechanism on this exact build. Four claims to validate, printed as [SpaceProbe] lines:
##
##   1. STEPPED  — physics simulates inside a SubViewport world on the server (no camera, no render):
##                 a body launched downward must move.
##   2. COLLIDED — bodies in that world collide with each other: the body must STOP on the ground
##                 slab instead of tunnelling through (gravity_scale 0 + manual velocity, so the
##                 result does not depend on the project's default gravity).
##   3. ISOLATED — the sub-world is invisible from the root world: the same ray that hits the ground
##                 inside the SubViewport must hit NOTHING when cast in the root world.
##   4. CHEAP    — queries in a near-origin sub-world cost ~origin price even though the ROOT world
##                 still holds the whole astronomic universe: replay the 400-box cluster there and
##                 expect ~5 us/ray (CoordProbe measured 5.26 us at planet-R, 172 us at astro).
##
## Runs once, ~20 s after server boot (lets the universe-load CPU storm settle so the us timings are
## clean), then frees everything it created. Delete this file together with coord_probe.gd.

const SETTLE_FRAMES: int = 90   # 1.5 s at 60 Hz: the drop takes ~0.5 s, the rest is margin
const DROP_FROM: float = 5.0
const DROP_SPEED: float = 10.0
const CLUSTER_AT := Vector3(500.0, 0.0, 0.0)  # keep the 400-box cluster clear of the drop rig


static func run(host: Node) -> void:
	var tree: SceneTree = host.get_tree()
	if tree == null:
		print("[SpaceProbe] no tree, skipped")
		return
	await tree.create_timer(20.0).timeout

	# ── The sub-world: physics only, never rendered ───────────────────────────────────────────────
	var sv := SubViewport.new()
	sv.name = "SpaceProbeWorld"
	sv.own_world_3d = true
	sv.size = Vector2i(2, 2)
	sv.render_target_update_mode = SubViewport.UPDATE_DISABLED
	host.add_child(sv)

	# Ground slab at the sub-world origin + a body launched down onto it.
	var ground := _box_body(sv, StaticBody3D.new(), Vector3(20.0, 1.0, 20.0), Vector3(0.0, -0.5, 0.0))
	var rb := RigidBody3D.new()
	rb.gravity_scale = 0.0  # claim 2 must not depend on the project's default gravity
	_box_body(sv, rb, Vector3.ONE, Vector3(0.0, DROP_FROM, 0.0))
	rb.linear_velocity = Vector3(0.0, -DROP_SPEED, 0.0)

	for _i in SETTLE_FRAMES:
		await tree.physics_frame

	# ── Claims 1 + 2: it moved, and it stopped ON the slab ────────────────────────────────────────
	var y: float = rb.position.y
	var stepped: bool = y < DROP_FROM - 0.1
	var collided: bool = stepped and y > -1.0  # tunnelled through => y ≈ DROP_FROM - DROP_SPEED * 1.5s
	print("[SpaceProbe] 1 STEPPED  %s — body y=%.2f (started %.1f)" % ["OK" if stepped else "FAIL", y, DROP_FROM])
	print("[SpaceProbe] 2 COLLIDED %s — %s" % ["OK" if collided else "FAIL",
		"resting on the slab" if collided else ("never moved" if not stepped else "TUNNELLED through the slab")])

	# ── Claim 3: same ray, both worlds ────────────────────────────────────────────────────────────
	var sub_space: PhysicsDirectSpaceState3D = sv.find_world_3d().direct_space_state
	var root_space: PhysicsDirectSpaceState3D = host.get_viewport().find_world_3d().direct_space_state
	var ray := PhysicsRayQueryParameters3D.create(Vector3(0.0, 3.0, 0.0), Vector3(0.0, -3.0, 0.0), 1)
	var sub_hit: bool = not sub_space.intersect_ray(ray).is_empty()
	var root_hit: bool = not root_space.intersect_ray(ray).is_empty()
	print("[SpaceProbe] 3 ISOLATED %s — sub-world ray hit=%s, root-world ray hit=%s (want true/false)"
		% ["OK" if (sub_hit and not root_hit) else "FAIL", sub_hit, root_hit])

	# ── Claim 4: the 400-box cluster, near origin, inside the sub-world ──────────────────────────
	var bodies: Array = []
	for o in CoordProbe._cluster_offsets():
		bodies.append(CoordProbe._make_box(sv, CLUSTER_AT + o))
	await tree.physics_frame
	await tree.physics_frame
	var hit_us := CoordProbe._time_rays_mask(sub_space, CLUSTER_AT, 1)
	var miss_us := CoordProbe._time_rays_mask(sub_space, CLUSTER_AT, 2)
	print("[SpaceProbe] 4 CHEAP    %s — 400-box cluster in sub-world: hitting ray %.2f us | missing ray %.2f us (astro control was ~172/18)"
		% ["OK" if hit_us < 30.0 else "FAIL", hit_us, miss_us])

	for b in bodies:
		(b as Node).queue_free()
	ground.queue_free()
	rb.queue_free()
	sv.queue_free()
	print("[SpaceProbe] done — everything freed")


## Give [param body] a box collider of [param size], add it under [param parent] at [param at].
static func _box_body(parent: Node, body: PhysicsBody3D, size: Vector3, at: Vector3) -> PhysicsBody3D:
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	col.shape = box
	body.add_child(col)
	body.collision_layer = 1
	body.collision_mask = 1
	parent.add_child(body)
	body.position = at
	return body
