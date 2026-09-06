@tool
class_name BridgeSpawner
## Builds the bridge that carries a road over a chasm found by [RoadBridge].
##
## Follows the shape of CaveSpawner: a static spawn() returning a node ready to
## be added to the tree, called from PlanetTerrain on BOTH the client and the
## server. The server needs it too — the deck carries the only collision over
## the gorge, so without it a vehicle drives along the road ribbon and falls
## straight through.
##
## ── Why there is no bridge SCENE any more ───────────────────────────────
## This used to instance a straight modular scene and place it with one
## transform, which produced the four things that were wrong in game:
##   · a straight module oriented by the rim-to-rim chord CUT THE CORNER of a
##     curved road, and its ends drifted off the tarmac;
##   · its altitude came from ONE height sample at the span midpoint, so on
##     sloping ground the far end was buried in the high rim — which reads as
##     "the bridge stops before the edge" — and floated over the low one;
##   · being flat and at one altitude, a rim higher than the midpoint was a
##     step the truck could not climb;
##   · it was assembled from repeated bays, and a bay seam is a dip a vehicle's
##     suspension unloads over, which costs grip on a raycast vehicle.
##
## The deck is now GENERATED from the road's own centerline (BridgeDeck), level
## at the higher rim's altitude (BridgePlan), with a ramp at each end. One mesh,
## one collision shape, no seams, no orientation to get wrong — the geometry is
## built directly in a world-aligned local frame.
##
## The road ribbon is cut to match, by PlanetChunk reading the same plans; the
## two must agree, which is why a span that cannot be planned produces neither a
## deck nor a cut.

## Chunk LOD at or below which bridges are spawned. Deliberately looser than
## CaveSpawner's gate: a 300 m deck reads from much further away than a cave
## mouth, and a road that visibly stops at a gorge is worse than no road.
const MAX_LOD := 3

static var _material_cache: Dictionary = {}
static var _warned_missing_material: Dictionary = {}


## Build the bridge for [param span] (a RoadBridge span dictionary).
##
## The two trailing arguments are DEPRECATED and ignored. They used to be the
## asking chunk's height tile, which made the deck's altitude a function of the
## observer's LOD: the deck moved on every LOD flip, and the client and the
## server — whose reference positions differ — could place the visible deck and
## the collision deck at different heights. The plan pins its own tile at
## export_nside from the span's midpoint instead.
##
## Returns the root node, or null when the span cannot be bridged.
static func spawn(planet_data: PlanetData, span: Dictionary,
		_height_ipix: int = -1, _height_nside: int = -1) -> Node3D:
	if span.get("truncated", false):
		# Too oblique to bridge — re-route the road instead. Reported by
		# PlanetData.get_bridge_spans() so it is not silently dropped.
		return null
	var plan := planet_data.get_bridge_plan(span)
	if plan.is_empty() or not bool(plan.get("ok", false)):
		# No plan means no ribbon cut either, so the road stays whole and the
		# player drives over a gorge on a ribbon instead of into a gap.
		return null
	var road := planet_data.get_whole_road(int(span.get("feature_id", -1)))
	if road.is_empty():
		return null

	var profile := planet_data.get_bridge_profile()
	var ipix: int = HEALPix.vec2pix_nest(planet_data.export_nside,
			span["mid_dir"])
	var geo := BridgeDeck.build(profile, plan, road, planet_data.radius,
			planet_data.bridge_height_sampler(ipix))
	if geo.is_empty():
		return null

	var body := StaticBody3D.new()
	body.name = "Bridge_" + PlanetData.bridge_span_key(span)
	# Same identity as a terrain chunk's collision body: the deck IS the ground
	# over the gorge, so anything that scans the world must find it the same
	# way. The old placeholder scene left Godot's defaults, which merely
	# happened to overlap.
	body.collision_layer = Globals.LAYER_WORLD
	body.set_collision_layer_value(Globals.LAYER_WORLD, true)
	body.collision_mask = Globals.MASK_SOLID
	body.position = geo["origin"]
	# Grip, read back by the vehicle: Godot's VehicleWheel3D derives its
	# friction budget from suspension force x wheel_friction_slip and never
	# looks at the ground body's PhysicsMaterial, so a per-surface value has to
	# travel as metadata. The PhysicsMaterial below is for everything else that
	# lands on the deck — crates, debris — which does use it.
	body.set_meta("grip_slip", profile.deck_grip_slip)
	var pm := PhysicsMaterial.new()
	pm.friction = 1.0
	pm.rough = true
	body.physics_material_override = pm

	var mi := MeshInstance3D.new()
	mi.name = "Deck"
	mi.mesh = geo["mesh"]
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_apply_materials(mi, profile)
	body.add_child(mi)

	var col := CollisionShape3D.new()
	col.name = "DeckCollision"
	col.shape = geo["shape"]
	body.add_child(col)

	body.set_meta("bridge_span", span)
	body.set_meta("bridge_plan", plan)
	return body


## Surface 0 is the driving surface, surface 1 the structure — the order
## BridgeDeck commits them in.
static func _apply_materials(mi: MeshInstance3D, profile: BridgeProfile) -> void:
	var paths := [profile.deck_material_path, profile.structure_material_path]
	for i in mini(paths.size(), mi.mesh.get_surface_count()):
		var mat := _load_material(String(paths[i]))
		if mat != null:
			mi.set_surface_override_material(i, mat)


static func _load_material(path: String) -> Material:
	if _material_cache.has(path):
		return _material_cache[path]
	var mat: Material = null
	if ResourceLoader.exists(path):
		mat = ResourceLoader.load(path) as Material
	if mat == null and not _warned_missing_material.has(path):
		_warned_missing_material[path] = true
		push_warning("[BridgeSpawner] bridge material not found: '%s' — the "
				% path + "deck renders untextured.")
	_material_cache[path] = mat
	return mat
