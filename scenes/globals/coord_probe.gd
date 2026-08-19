class_name CoordProbe
extends RefCounted

## TEMPORARY diagnostic (TPS drops, étape 0e). Why is EVERY physics query on this server ~100x slower
## than it should be? A 3 m intersect_ray costs ~200-580 us and one move_and_slide costs 1.8-3.4 ms,
## for a single character. That is not specific to the character controller (plain raycasts are just as
## slow), so it is not a CharacterBody3D setting — it is the whole query path.
##
## Two candidate causes, and this probe separates them by casting the SAME short ray against the SAME
## BoxShape3D in three places:
##
##   A — near the world origin, empty space          → baseline: what a query should cost
##   B — at the player's DISTANCE from origin, but 50 km above the surface, empty space
##                                                    → isolates COORDINATE MAGNITUDE
##   C — at the player's exact position, terrain and props all around
##                                                    → isolates LOCAL COLLIDER DENSITY
##
## B >> A means coordinate magnitude is the cause: a broadphase that quantises AABBs in float32 has a
## ~2 km resolution at 2.6e10 m, so a 3 m ray returns candidates from kilometres away. The fix would be
## a server-side origin rebase, not any script optimisation. C >> B means the cause is instead how many
## colliders sit around the player, and the fix is on the terrain/prop side.
##
## Runs once and frees its bodies. Delete this file together with the PropNet.PROF block.

const RAYS: int = 200          # bounded: at the measured ~500 us/ray this costs ~100 ms per site, once
const BOX_SIZE: float = 2.0
const RAY_HALF: float = 3.0
const EMPTY_ALT: float = 50000.0  # m above the surface for site B — far enough to be in clear space


## [param reference] is the player (any Node3D at the far position). Not awaited by the caller: the
## bodies need a physics step to enter the broadphase before the timings mean anything.
static func run(reference: Node3D) -> void:
	var tree: SceneTree = reference.get_tree()
	var world: World3D = reference.get_world_3d()
	if tree == null or world == null:
		print("[CoordProbe] no tree/world, skipped")
		return
	var host: Node = reference.get_parent()
	if not (host is Node3D):
		host = reference
	var at_player: Vector3 = reference.global_position
	if at_player.length() < 1.0:
		print("[CoordProbe] reference is already at the origin, nothing to compare")
		return
	# Site B: same distance from origin, but pushed radially out of the terrain into empty space.
	var at_far_empty: Vector3 = at_player.normalized() * (at_player.length() + EMPTY_ALT)
	var at_near: Vector3 = Vector3(1000.0, 1000.0, 1000.0)

	var b_near := _make_box(host, at_near)
	var b_far := _make_box(host, at_far_empty)
	var b_player := _make_box(host, at_player)
	# Let Jolt register all three in the broadphase before timing anything.
	await tree.physics_frame
	await tree.physics_frame

	var space: PhysicsDirectSpaceState3D = world.direct_space_state
	if space == null:
		print("[CoordProbe] no space state, skipped")
		b_near.queue_free(); b_far.queue_free(); b_player.queue_free()
		return
	var us_near := _time_rays(space, at_near)
	var us_far := _time_rays(space, at_far_empty)
	var us_player := _time_rays(space, at_player)
	# NOTE: %e is NOT a supported format character in GDScript (it errors and prints the raw format
	# string) — distances go out in km with %.0f.
	print("[CoordProbe] %d rays/site | A near origin (%.0f km): %.2f us | B far+empty (%.0f km): %.2f us (%.1fx A) | C player pos: %.2f us (%.1fx A, %.1fx B)" % [
		RAYS,
		at_near.length() / 1000.0, us_near,
		at_far_empty.length() / 1000.0, us_far, us_far / maxf(us_near, 0.001),
		us_player, us_player / maxf(us_near, 0.001), us_player / maxf(us_far, 0.001),
	])
	b_near.queue_free()
	b_far.queue_free()
	b_player.queue_free()
	_probe_local_density(space, at_player, up_of(at_player))
	await _density_vs_distance(tree, host, world, at_far_empty, at_near)


## Site C costs 32x site B for the same ray on the same box, so the cost comes from what surrounds the
## player — not from the distance to the origin. Two explanations remain, and this separates them:
## either there really are hundreds of colliders within metres (a scene problem), or the broadphase
## over-reports distant candidates (a precision problem, invisible at site B because nothing was there
## to report). Counting the ACTUAL overlaps settles it: a handful of real neighbours with a 200 us ray
## means the broadphase is handing the narrowphase work it should have rejected.
static func _probe_local_density(space: PhysicsDirectSpaceState3D, at: Vector3, up: Vector3) -> void:
	var last_hits: Array = []
	for radius in [0.5, 3.0, 20.0]:
		var q := PhysicsShapeQueryParameters3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = radius
		q.shape = sphere
		q.transform = Transform3D(Basis(), at)
		q.collision_mask = 0xFFFFFFFF
		var t0 := Time.get_ticks_usec()
		var hits: Array = space.intersect_shape(q, 512)
		var us := Time.get_ticks_usec() - t0
		print("[CoordProbe] overlaps within %.1f m: %d colliders (query %d us)" % [radius, hits.size(), us])
		last_hits = hits
	_inventory(last_hits, at)
	# Which layer carries the cost: terrain chunks (1) or props / others.
	for mask in [1, 2, 4, 8, 15]:
		var from_pos: Vector3 = at + up * RAY_HALF
		var to_pos: Vector3 = at - up * RAY_HALF
		var t0 := Time.get_ticks_usec()
		for _i in RAYS:
			space.intersect_ray(PhysicsRayQueryParameters3D.create(from_pos, to_pos, mask))
		print("[CoordProbe] ray at player, mask=%d: %.2f us/ray" % [
			mask, float(Time.get_ticks_usec() - t0) / float(RAYS)])


static func up_of(at: Vector3) -> Vector3:
	return at.normalized() if at.length() > 1.0 else Vector3.UP


## What ARE the 439 colliders around the player? Query cost grows roughly linearly with their count
## (~0.38 us each at this distance from the origin), so cutting the count cuts the cost — and unlike an
## origin rebase, it works on every planet and in every deployment. This breaks the set down by class,
## by scene file and by collision layer, and separately counts the SHAPES each body carries: a body
## with 30 CollisionShape3D children costs like 30 colliders, and merging those is usually the easiest
## win. The settle-culler only ever freezes RigidBody3D, so any StaticBody3D here is never culled.
static func _inventory(hits: Array, at: Vector3) -> void:
	if hits.is_empty():
		return
	var by_class: Dictionary = {}
	var by_scene: Dictionary = {}
	var by_layer: Dictionary = {}
	var dist_max: Dictionary = {}   # per scene: furthest collider ORIGIN reported as overlapping
	var shapes_total := 0
	var frozen_rigid := 0
	for h in hits:
		var col = h.get("collider")
		if not is_instance_valid(col):
			continue
		var cls: String = col.get_class()
		by_class[cls] = int(by_class.get(cls, 0)) + 1
		var scene: String = (col as Node).scene_file_path
		if scene == "":
			scene = "(no scene) " + (col as Node).name
		by_scene[scene] = int(by_scene.get(scene, 0)) + 1
		# Sanity check on placement: intersect_shape returns REAL overlaps, so a body whose origin is
		# hundreds of metres away yet "overlaps" a 20 m sphere has collision geometry nowhere near
		# itself — i.e. shapes attached at the wrong transform.
		if col is Node3D:
			var d: float = (col as Node3D).global_position.distance_to(at)
			if d > float(dist_max.get(scene, 0.0)):
				dist_max[scene] = d
		if col is CollisionObject3D:
			var layer: int = (col as CollisionObject3D).collision_layer
			by_layer[layer] = int(by_layer.get(layer, 0)) + 1
			shapes_total += (col as CollisionObject3D).get_shape_owners().size()
		if col is RigidBody3D and (col as RigidBody3D).freeze:
			frozen_rigid += 1
	print("[CoordProbe] inventory of %d colliders: %d shape owners total, %d frozen RigidBody3D" % [
		hits.size(), shapes_total, frozen_rigid])
	print("[CoordProbe]   by class: %s" % [by_class])
	print("[CoordProbe]   by layer: %s" % [by_layer])
	# Scenes sorted by count, worst first — that is where the merging effort pays.
	var scenes: Array = by_scene.keys()
	scenes.sort_custom(func(a, b): return int(by_scene[a]) > int(by_scene[b]))
	for i in mini(scenes.size(), 12):
		print("[CoordProbe]   %4d x (furthest origin %.1f m) %s" % [
			int(by_scene[scenes[i]]), float(dist_max.get(scenes[i], 0.0)), scenes[i]])
	if scenes.size() > 12:
		print("[CoordProbe]   ... and %d more distinct scenes" % [scenes.size() - 12])


## THE decision test. Two effects compound at the player: an inflated broadphase (a float32 AABB has a
## ~2 km resolution at 3.3e10 m) and real local density (431 colliders within 20 m). Which one do we
## pay to fix? Build the SAME controlled cluster twice — identical count, identical relative offsets,
## identical shapes — once near the origin and once at the player's distance in empty space. Density is
## then held constant and only the coordinates differ.
##
##   near ≈ far  → density is the whole story; fix the scene (merge the depot's static colliders).
##   near ≪ far  → the coordinates are; fix it by simulating near the origin (server-side rebase).
##
## The mask=2 rays are the cleanest signal: nothing in either cluster is on layer 2, so their entire
## cost is the broadphase handing the narrowphase candidates it should have rejected.
const CLUSTER_N: int = 400
const CLUSTER_R: float = 20.0

static func _density_vs_distance(tree: SceneTree, host: Node, world: World3D,
		at_far: Vector3, at_near: Vector3) -> void:
	# Étape 0 of the rebase plan: what WILL a query cost after the rebase? The same 400-box
	# cluster, at four distances from the scene origin — empty space at every site, so density
	# is held constant and only the coordinate magnitude varies:
	#   origin    control: the best case (f32 ULP ~1e-4 m)
	#   planet-R  where a planet-at-origin server puts a surface player (6.36e6 m -> ULP 0.5 m)
	#   slot-max  worst parking slot of the multi-planet single-scene layout (4e7 m -> ULP 4 m)
	#   astro     today's coordinates (3.3e10 m -> ULP 2048 m), the known-bad control
	# If planet-R comes back near the origin cost, the rebase (single-offset or per-planet
	# server) is validated; if it is still ~100 us, no origin rebase can save the tick rate.
	var dir: Vector3 = at_far.normalized()
	var sites: Array = [
		{"label": "origin   (1.7e3 m)", "pos": at_near},
		{"label": "planet-R (6.4e6 m)", "pos": dir * 6.356e6},
		{"label": "slot-max (4.0e7 m)", "pos": dir * 4.0e7},
		{"label": "astro    (3.3e10 m)", "pos": at_far},
	]
	var offsets := _cluster_offsets()
	var bodies: Array = []
	for s in sites:
		for o in offsets:
			bodies.append(_make_box(host, (s["pos"] as Vector3) + o))
	await tree.physics_frame
	await tree.physics_frame
	var space: PhysicsDirectSpaceState3D = world.direct_space_state
	if space == null:
		print("[CoordProbe] density test: no space state")
	else:
		print("[CoordProbe] DENSITY TEST — %d boxes within %.0f m, identical at %d sites" % [
			CLUSTER_N, CLUSTER_R, sites.size()])
		for s in sites:
			var pos: Vector3 = s["pos"]
			var hit := _time_rays_mask(space, pos, 1)
			var miss := _time_rays_mask(space, pos, 2)
			print("[CoordProbe]   %s: hitting ray %.2f us | missing ray %.2f us" % [
				s["label"], hit, miss])
	for b in bodies:
		(b as Node).queue_free()


## Deterministic spread through a ball of CLUSTER_R, so both sites get byte-identical geometry (a
## random scatter would make the two timings incomparable). Index 0 is the centre, so the mask=1 ray
## always has something to hit.
static func _cluster_offsets() -> Array:
	var out: Array = []
	out.append(Vector3.ZERO)
	var golden := PI * (3.0 - sqrt(5.0))
	for i in range(1, CLUSTER_N):
		var t := float(i) / float(CLUSTER_N)
		var radius := CLUSTER_R * pow(t, 1.0 / 3.0)
		var z := 1.0 - 2.0 * t
		var ring := sqrt(maxf(0.0, 1.0 - z * z))
		var a := golden * float(i)
		out.append(Vector3(cos(a) * ring, z, sin(a) * ring) * radius)
	return out


static func _time_rays_mask(space: PhysicsDirectSpaceState3D, at: Vector3, mask: int) -> float:
	var up := up_of(at)
	var from_pos: Vector3 = at + up * RAY_HALF
	var to_pos: Vector3 = at - up * RAY_HALF
	var t0 := Time.get_ticks_usec()
	for _i in RAYS:
		space.intersect_ray(PhysicsRayQueryParameters3D.create(from_pos, to_pos, mask))
	return float(Time.get_ticks_usec() - t0) / float(RAYS)


static func _make_box(host: Node, at: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0  # queried only, never collides with anything itself
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3.ONE * BOX_SIZE
	col.shape = box
	body.add_child(col)
	host.add_child(body)
	(body as Node3D).global_position = at
	return body


## Cast RAYS identical short rays straight down through the box at [param at]. The hit count guards
## against timing a ray that misses everything (which would measure nothing).
static func _time_rays(space: PhysicsDirectSpaceState3D, at: Vector3) -> float:
	var up: Vector3 = up_of(at)
	var from_pos: Vector3 = at + up * RAY_HALF
	var to_pos: Vector3 = at - up * RAY_HALF
	var hits := 0
	var t0 := Time.get_ticks_usec()
	for _i in RAYS:
		var q := PhysicsRayQueryParameters3D.create(from_pos, to_pos, 1)
		if not space.intersect_ray(q).is_empty():
			hits += 1
	var elapsed := Time.get_ticks_usec() - t0
	if hits == 0:
		print("[CoordProbe] WARNING: 0/%d rays hit at %v — that site's timing is meaningless" % [RAYS, at])
	return float(elapsed) / float(RAYS)
