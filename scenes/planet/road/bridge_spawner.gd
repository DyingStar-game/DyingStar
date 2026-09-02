@tool
class_name BridgeSpawner
## Places a bridge over a road/chasm crossing found by [RoadBridge].
##
## Follows the shape of CaveSpawner: a static spawn() returning a node ready to
## be added to the tree, called from PlanetTerrain on BOTH the client and the
## server. The server needs it too — the bridge carries the only collision over
## the gorge, so without it a vehicle drives along the road ribbon and falls
## straight through.
##
## ── Bridge scene contract ──────────────────────────────────────────────
## A bridge scene declares its own geometry through metadata on its ROOT node,
## rather than relying on a pivot convention. Assets differ (wind_valley's
## origin sits at the base of its piers, ~97 m below the deck), and a metadata
## field is checked at load time whereas a mis-authored pivot is only visible
## in game.
##
##     metadata/deck_height  float  height of the driving surface above the
##                                  scene origin, in metres
##     metadata/span_length  float  distance between abutments, in metres
##     metadata/road_width   float  usable deck width, in metres (optional)
##     metadata/repeatable   bool   true when the scene is one bay that may be
##                                  repeated along the span to cover any length
##
## and on each CHILD that makes up the cross-section:
##
##     metadata/deck_role    String "surface" — the driving slab, widened or
##                                  narrowed to the road the bridge carries;
##                                 "edge"    — kerb or parapet, keeps its own
##                                  section and slides to the new deck edge
##
## Without those roles the module is used at its authored width. They are what
## lets ONE module serve a 1 m footpath and a 12 m highway: scaling the node
## instead would thin the parapets in proportion, and a parapet is sized by what
## a vehicle can cross in one physics step, not by how wide the road is.
##
## A scene without `deck_height` is assumed to have its origin ON the deck
## (deck_height = 0) and a warning is emitted once — that is the convention a
## purpose-built module would use, but guessing silently would drop bridges
## 100 m below the road.

## Scene instanced for every crossing. Replace with the real modular asset;
## the fallback below is built from primitives so the mechanism can be
## validated before the art exists.
const BRIDGE_SCENE_PATH := "res://scenes/_universe/structures/industrial/bridge_module.tscn"

## Chunk LOD at or below which bridges are spawned. Deliberately looser than
## CaveSpawner's gate: a 300 m deck reads from much further away than a cave
## mouth, and a road that visibly stops at a gorge is worse than no road.
const MAX_LOD := 3

static var _scene_cache: Dictionary = {}
static var _warned_missing_meta: Dictionary = {}
static var _warned_missing_tile: Dictionary = {}


## Instance a bridge for [param span] (a RoadBridge span dictionary).
##
## [param height_ipix] / [param height_nside] are the pyramid tile the OWNING
## CHUNK samples its heights from (PlanetTerrain._chunk_height_tile). Pass them:
## the deck has to land on the road ribbon, and the ribbon's altitude depends on
## which tile drew it. -1 / -1 falls back to the finest level, which is only
## right for a chunk at or below nside_max.
##
## Returns the root node, or null when the span cannot be bridged.
static func spawn(planet_data: PlanetData, span: Dictionary,
		height_ipix: int = -1, height_nside: int = -1) -> Node3D:
	if span.get("truncated", false):
		# Too oblique to bridge — re-route the road instead. Reported by
		# PlanetData.get_bridge_spans() so it is not silently dropped.
		return null

	var scene := _load_scene(BRIDGE_SCENE_PATH)
	if scene == null:
		return null
	var node := scene.instantiate() as Node3D
	if node == null:
		return null

	var deck_height := _meta(node, "deck_height", 0.0, BRIDGE_SCENE_PATH)
	var span_length := float(node.get_meta("span_length", 0.0))
	var deck_span: float = float(span["deck_span_m"])

	# The deck must sit at the altitude the ROAD RIBBON uses, which samples the
	# raw heightmap and therefore ignores the crack. Sampling the same way here
	# is what makes the deck line up with the visible road instead of with the
	# carved gorge floor underneath it.
	#
	# "The same way" means all three of these, and missing any one leaves the
	# deck a decimetre off the road it is supposed to continue:
	#   · the same PYRAMID LEVEL — a chunk coarser than nside_max reads its own
	#     coarse tile (PlanetData.sample_nside_for), not the finest one;
	#   · the same TILE — passing the chunk's ipix instead of letting vec2pix
	#     pick one, which disagrees at a tile seam;
	#   · the ribbon's SURFACE_OFFSET, the few centimetres it is lifted by to
	#     stay off the terrain mesh (PlanetChunk builds it at h + that offset).
	var mid_dir: Vector3 = span["mid_dir"]
	var ns: int = height_nside if height_nside > 0 else planet_data.export_nside
	var ipix: int = height_ipix if height_ipix >= 0 else HEALPix.vec2pix_nest(ns, mid_dir)
	# A missing tile makes sample_height_for_direction fall back to the global
	# equirect map — a different, flatter surface, which is what put the props
	# kilometres above the terrain on tarsis_3. The chunk mesh cache already
	# refuses to persist a mesh built that way; a bridge built that way lands
	# nowhere near its road, and worse, the client and the server stop agreeing
	# as soon as only ONE of them has the tile cached — a deck you can see but
	# not drive on, or collision hanging in the air.
	if planet_data.load_chunk_heightmap(ipix, ns) == null:
		if not _warned_missing_tile.has(ipix):
			_warned_missing_tile[ipix] = true
			push_warning("[BridgeSpawner] no height tile n%d/p%d — skipping the "
					% [ns, ipix] + "bridge rather than placing it on the equirect "
					+ "fallback surface, which the road ribbon does not use.")
		return null
	var deck_alt: float = planet_data.sample_height_for_direction(mid_dir,
			height_ipix, -1, Vector2i(-1, -1), null, height_nside)
	var origin_radius: float = (planet_data.radius + deck_alt
			+ RoadTerrain.SURFACE_OFFSET - deck_height)
	node.position = mid_dir * origin_radius

	# Orient: +Y away from the planet centre, +X along the road.
	#
	# The deck direction comes ready-made from the span as a world vector
	# (RoadBridge builds it from the rim-to-rim chord) rather than being rebuilt
	# here out of an east/north frame — see _forward_from_bearing() for why that
	# frame is a trap.
	var up := mid_dir.normalized()
	var forward: Vector3 = span.get("forward_dir", Vector3.ZERO)
	forward -= up * forward.dot(up)
	if forward.length_squared() < 1e-12:
		forward = _forward_from_bearing(up, span.get("bearing", Vector2.RIGHT))
	forward = forward.normalized()
	# +Z = X × Y. Taking up × forward instead gives a determinant of -1, which
	# mirrors the whole module about its own axis.
	var side := forward.cross(up).normalized()
	node.basis = Basis(forward, up, side)

	# Build the deck to the width of its own road: a 12 m slab under a 6 m road
	# reads as a runway dropped over the gorge. The span carries the width, so a
	# track and a highway get different bridges out of the same module. Done
	# BEFORE the bays are laid so every bay inherits the new section.
	var road_w: float = float(span.get("road_width_m", 0.0))
	if road_w <= 0.0:
		road_w = float(node.get_meta("road_width", 0.0))
	if road_w > 0.0:
		_fit_deck_width(node, road_w)

	# Stretch or repeat to cover the gap.
	if span_length > 0.0:
		if bool(node.get_meta("repeatable", false)):
			_repeat_bays(node, span_length, deck_span)
		else:
			node.scale = Vector3(deck_span / span_length, 1.0, 1.0)

	node.name = "Bridge_f%d_%d" % [int(span.get("feature_id", -1)),
			int(span.get("along_start", 0.0))]
	node.set_meta("bridge_span", span)
	return node


## Deck direction from an east/north bearing, for spans that carry no
## `forward_dir`.
##
## Watch the handedness: longitude is atan2(z, x), so eastward runs +X → +Z and
## the (east, north, up) triple is LEFT-handed in Godot's Y-up world. up × east
## therefore points SOUTH, not north — build the deck on it and a road heading
## north-east gets a bridge heading south-east, mirrored about the east axis.
static func _forward_from_bearing(up: Vector3, bearing: Vector2) -> Vector3:
	var east := Vector3(-up.z, 0.0, up.x)
	if east.length_squared() < 1e-12:
		east = Vector3(1.0, 0.0, 0.0)
	east = east.normalized()
	var north := east.cross(up).normalized()
	var f := east * bearing.x + north * bearing.y
	return f if f.length_squared() > 1e-12 else east


## Resize the module so the CLEAR width between its edge pieces is
## [param clear_width] — i.e. the driving surface matches the road, and the
## parapets border it rather than eating into it.
static func _fit_deck_width(root: Node3D, clear_width: float) -> void:
	# Pass 1: each edge keeps its section and moves so the gap between the two
	# of them is exactly the road width.
	var edge_thickness := 0.0
	for c in root.get_children():
		var c3 := c as Node3D
		if c3 == null or String(c3.get_meta("deck_role", "")) != "edge":
			continue
		var t: float = _box_size(c3).z
		if t <= 0.0:
			continue
		edge_thickness = maxf(edge_thickness, t)
		var side := -1.0 if c3.position.z < 0.0 else 1.0
		c3.position.z = side * 0.5 * (clear_width + t)
	# Pass 2: the slab spans the road AND the two edges standing on it, so no
	# parapet ends up overhanging thin air.
	for c in root.get_children():
		var c3 := c as Node3D
		if c3 == null or String(c3.get_meta("deck_role", "")) != "surface":
			continue
		var sz: Vector3 = _box_size(c3)
		if sz.z <= 0.0:
			continue
		_set_box_size(c3, Vector3(sz.x, sz.y, clear_width + 2.0 * edge_thickness))


## Size of a box mesh or box collision shape, or ZERO for anything else.
static func _box_size(node: Node3D) -> Vector3:
	if node is MeshInstance3D:
		var bm := (node as MeshInstance3D).mesh as BoxMesh
		if bm != null:
			return bm.size
	elif node is CollisionShape3D:
		var bs := (node as CollisionShape3D).shape as BoxShape3D
		if bs != null:
			return bs.size
	return Vector3.ZERO


## Resize a box mesh/shape, on a COPY of the resource. A .tscn sub-resource is
## shared by every instance of the scene, so writing to it in place would
## rebuild every other bridge on the planet to the width of the last road
## spawned — including the ones already standing.
static func _set_box_size(node: Node3D, size: Vector3) -> void:
	if node is MeshInstance3D:
		var bm := (node as MeshInstance3D).mesh as BoxMesh
		if bm != null:
			var mesh_copy: BoxMesh = bm.duplicate()
			mesh_copy.size = size
			(node as MeshInstance3D).mesh = mesh_copy
	elif node is CollisionShape3D:
		var bs := (node as CollisionShape3D).shape as BoxShape3D
		if bs != null:
			var shape_copy: BoxShape3D = bs.duplicate()
			shape_copy.size = size
			(node as CollisionShape3D).shape = shape_copy


## Repeat a single-bay module along +X until the span is covered.
## Bays are laid symmetrically about the origin so the module stays centred on
## the crossing.
##
## Only the VISUALS are tiled. Every box collision shape is STRETCHED to the
## whole deck instead, because tiled shapes are not a continuous surface: two
## boxes butted end to end meet at a seam, and a physics engine rounds a convex
## shape's edges by its collision margin, so each seam is a small dip. A vehicle
## crossing one every bay length is bumped, unloads its suspension and — since
## Godot's VehicleWheel3D scales grip by suspension force — slides. One shape per
## surface has no seam to cross, and costs 3 shapes per bridge rather than 3 per
## bay.
static func _repeat_bays(root: Node3D, bay_length: float, deck_span: float) -> void:
	var bays: int = maxi(1, int(ceil(deck_span / bay_length)))
	var children: Array[Node] = []
	for c in root.get_children():
		children.append(c)
	# The meshes tile to whole bays, so the collision covers that same length —
	# never less, or the deck would end in a hole you can see but not drive on.
	var tiled_length := float(bays) * bay_length
	var start := -0.5 * (bays - 1) * bay_length

	for c in children:
		var c3 := c as Node3D
		if c3 == null:
			continue
		if _stretch_box_shape(c3, tiled_length):
			continue
		if bays <= 1:
			continue
		for b in range(1, bays):
			var dup := c3.duplicate() as Node3D
			dup.position = c3.position + Vector3(start + b * bay_length, 0.0, 0.0)
			root.add_child(dup)
	if bays <= 1:
		return
	for c in children:
		var c3 := c as Node3D
		if c3 != null and not (c3 is CollisionShape3D):
			c3.position += Vector3(start, 0.0, 0.0)


## Stretch a box collision shape along +X to [param length], centred on the
## module. Returns false for anything else, which the caller then tiles.
##
## The shape is DUPLICATED first: a .tscn sub-resource is shared by every
## instance of the scene, so resizing it in place would resize the deck of every
## bridge on the planet to whatever the last one spawned needed.
static func _stretch_box_shape(node: Node3D, length: float) -> bool:
	var cs := node as CollisionShape3D
	if cs == null:
		return false
	var box := cs.shape as BoxShape3D
	if box == null:
		# A non-box shape cannot be stretched without distorting it; let the
		# caller tile it and accept the seams.
		return false
	var stretched: BoxShape3D = box.duplicate()
	stretched.size.x = maxf(length, stretched.size.x)
	cs.shape = stretched
	cs.position.x = 0.0
	return true


static func _meta(node: Node3D, key: String, fallback: float, path: String) -> float:
	if node.has_meta(key):
		return float(node.get_meta(key))
	if not _warned_missing_meta.has(path + key):
		_warned_missing_meta[path + key] = true
		push_warning("[BridgeSpawner] %s has no metadata/%s — assuming %.1f. "
				% [path, key, fallback]
				+ "Set it on the scene root, or the deck will not line up "
				+ "with the road.")
	return fallback


static func _load_scene(path: String) -> PackedScene:
	if _scene_cache.has(path):
		return _scene_cache[path]
	var scene: PackedScene = null
	if ResourceLoader.exists(path):
		scene = ResourceLoader.load(path) as PackedScene
	if scene == null:
		push_warning("[BridgeSpawner] bridge scene not found: %s" % path)
	_scene_cache[path] = scene
	return scene
