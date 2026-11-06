class_name SurfaceProbe

## Answers ONE question: which taxonomy family is the surface at this point? — "metal", "sand",
## "snow"… taken from the `family` category of tools/schema/tags.json, or &"" when nothing answers.
##
## It knows nothing about audio. Callers turn a family into a footstep, an impact, a particle colour;
## adding a new consumer needs no change here. (Its first two consumers are the player's footsteps and
## a dropped prop's landing sound — the same question asked from two places.)
##
## Two worlds have to be told apart, because they are built differently:
##
##   • PROPS AND STRUCTURES carry a real material. The material library states the family IN THE ID:
##     `mat_<family>_<name>` (see tags.json — "a runtime script reads it to pick footstep sounds").
##     So we parse it, we do not guess. That is the whole difference with a name-substring match:
##     `mat_metal_diamondplate2k` is metal because the id SAYS so, not because the word appears in it.
##
##   • THE TERRAIN has no discrete material: it is a biome shader. So we ask the planet which biome
##     covers that direction and translate the biome to a family (see BIOME_FAMILY below).
##
## Unknown is a first-class answer, deliberately. Most of the material library predates the id
## convention, and inventing a family from a filename would put a wrong sound under your feet with
## the confidence of a right one.

## The id prefix every library material carries.
const MATERIAL_ID_PREFIX: String = "mat_"
## How far below a standing body we look for the ground. Clears half a standing height plus the settle
## into the terrain. Shared, so the footsteps and the debug readout cannot probe differently — a
## readout describing a surface the game never consulted would be worse than none.
const FOOT_REACH_M: float = 2.0

## Biome → family, in TWO levels, because 126 biome definitions cannot be tagged one by one.
## A biome type reads `<category>-<kind>`: we try the KIND first (specific), then the CATEGORY
## (generic). Fifteen lines cover the whole set, and a biome that deserves better overrides it with
## BiomeDefinition.surface_family.
const BIOME_KIND_FAMILY: Dictionary = {
	"snow": &"snow", "glacier": &"ice", "beach": &"sand", "sandy_desert": &"sand",
	"ash_desert": &"sand", "dune": &"sand", "ocean": &"liquid", "lake": &"liquid",
	"lava_lake": &"liquid", "swamp": &"mud", "bog": &"mud", "mangrove": &"mud",
	"delta": &"mud", "obsidian_field": &"stone", "volcanic_basalt": &"stone",
	"cliff": &"rock", "canyon": &"rock", "crater": &"rock",
}
const BIOME_CATEGORY_FAMILY: Dictionary = {
	"icy": &"snow", "aride_desert": &"sand", "maritime_river": &"sand",
	"wetland": &"mud", "volcanic_geothermal": &"rock", "rocky_landform": &"rock",
	"spatial": &"rock", "forest": &"vegetation", "meadow_steppe": &"vegetation",
}


## Which way is down for a body standing on a planet: its OWN up, inverted. Not up_direction, which is
## not dependable on a client, and not a normalised world position — at ~1e11 m that yields the
## star->planet direction, one constant for a whole globe.
static func down_of(body: Node3D) -> Vector3:
	return -body.global_basis.y.normalized()


## The family under a body standing somewhere — the entry point both consumers use.
##
## Two steps, and the second one is not a nicety: ON A CLIENT THE TERRAIN HAS NO COLLISION. Chunk
## residency is driven from server.gd alone (see PlanetTerrain.set_resident_chunks), which is also why
## client-side movement prediction was parked. So a ray cast downward outdoors hits NOTHING, and a
## probe that stopped there would report "unknown" on every patch of ground in the game.
##
## What a client does have is the planet and its data, and a biome lookup needs no collision at all —
## it is a question about a direction on a sphere. So: the ray first, because a prop, a vehicle or a
## structure under our feet DOES have collision on a client and must win; then the planet, because
## "nothing under me" on a planet means "the ground the ray cannot see".
static func family_under(body: Node3D, down: Vector3, reach: float, mask: int) -> StringName:
	return explain_under(body, down, reach, mask)["family"]


## Same probe, with its reasoning: {family, source, detail}. The debug readout calls THIS, so what it
## shows is what the game actually used — an instrument with a code path of its own would drift from
## the thing it measures, and be trusted anyway.
##   source  "objet" | "terrain" | "planete" | "aucun"   detail  what was found, or why nothing was
static func explain_under(body: Node3D, down: Vector3, reach: float, mask: int) -> Dictionary:
	if body == null or not body.is_inside_tree():
		return {"family": &"", "source": "aucun", "detail": "corps hors de l arbre"}
	var space := body.get_world_3d().direct_space_state
	if space == null:
		return {"family": &"", "source": "aucun", "detail": "pas d espace physique"}
	var params := PhysicsRayQueryParameters3D.create(
		body.global_position, body.global_position + down * reach)
	params.collision_mask = mask
	params.exclude = [_rid_of(body)]
	# NOT `:=` — an untyped Dictionary from the physics server breaks inference.
	var hit = space.intersect_ray(params)
	if not hit.is_empty():
		var collider = hit.get("collider")
		var terrain := _terrain_of(collider as Node) if collider is Node else null
		if terrain != null:
			var tf := _terrain_family(terrain, hit.get("position", Vector3.ZERO))
			return {"family": tf, "source": "terrain", "detail": _node_path_of(collider)}
		var point: Vector3 = hit.get("position", Vector3.ZERO)
		var mat := _material_of(collider as Node, point) if collider is Node else null
		var mf := family_of_material(mat) if mat != null else &""
		return {
			"family": mf, "source": "objet",
			"detail": _node_path_of(collider) + "  ->  " + _material_detail(mat),
		}
	# Nothing hit. On a CLIENT that is the normal case outdoors: terrain collision is server-only
	# (residency is driven from server.gd alone), so the ground is invisible to a ray. Ask the planet.
	var planet := _planet_of(body)
	if planet == null:
		return {"family": &"", "source": "aucun", "detail": "rien touche, et aucune planete au-dessus"}
	if planet.planet_data == null:
		return {"family": &"", "source": "aucun", "detail": "planete " + planet.name + " sans planet_data"}
	# Only within reach of the ground: from a station in orbit, "the ground the ray cannot see" is 400 km
	# down, and answering with it made a floating astronaut walk on Sandbox's corundum.
	if not planet.within_ground_reach(body.global_position):
		return {"family": &"", "source": "aucun", "detail": "loin du sol de " + planet.name}
	# to_local, never a global normalize: the planet sits at ~1e11 m on a client.
	var radial: Vector3 = planet.to_local(body.global_position)
	if radial.is_zero_approx():
		return {"family": &"", "source": "aucun", "detail": "position confondue avec le centre"}
	var biome = planet.planet_data.biome_at(radial.normalized())
	if biome == null:
		# No biome covers this spot — the normal case on open ground. Fall back to the body's own
		# default rather than reporting nothing: bare ground is bare ground.
		var default_family := StringName(planet.planet_data.surface_family)
		if default_family != &"":
			return {
				"family": default_family, "source": "planete",
				"detail": planet.name + " (sol par defaut, hors biome)",
			}
		return {
			"family": &"", "source": "planete",
			"detail": planet.name + " : hors biome ET aucune famille par defaut sur la planete",
		}
	return {
		"family": family_of_biome(biome), "source": "planete",
		"detail": planet.name + " / " + String(biome.biome_type),
	}


## Readable path of a node, for the debug readout only.
static func _node_path_of(node) -> String:
	if node == null or not (node is Node):
		return "(rien)"
	return String((node as Node).name)


## What a material is, said plainly: its file when it has one, else the fact that it is inline —
## which is itself the answer, since an inline material has no id and so no family.
static func _material_detail(mat: Material) -> String:
	if mat == null:
		return "aucun materiau trouve"
	var named: String = mat.resource_name
	var path: String = mat.resource_path
	var where: String = path.get_file() if not path.is_empty() else "sans fichier"
	if named.is_empty():
		return where + " (sans nom de ressource)"
	return named + " dans " + where


## The Planet a body stands on, or null — for the other consumers of the probe (the dust reads its
## ground colour and its air there). See _planet_of.
static func planet_of(node: Node) -> Planet:
	return _planet_of(node)


## The Planet a body stands on, or null.
##
## Two ways, because neither alone is dependable. Walking UP the tree is the general one — a body is
## often parented to a city or a building rather than to the planet — but a player released to deep
## space, or parented to something outside the planet's subtree, escapes it. The GRAVITY parent is the
## other: it is how the altitude readout finds its planet, and that one demonstrably works. The
## gravity area sits under PlanetTerrain, itself under the Planet — hence the two get_parent().
static func _planet_of(node: Node) -> Planet:
	var walk: Node = node
	while walk != null:
		if walk is Planet:
			return walk as Planet
		walk = walk.get_parent()
	if node != null and node.has_method("get_current_gravity_parent"):
		var area = node.get_current_gravity_parent()
		if area != null and area.get_parent() != null:
			var owner_node = area.get_parent().get_parent()
			if owner_node is Planet:
				return owner_node as Planet
	return null


## A body's own RID, so it stays out of its own probe. Zero for anything that is not a collider.
static func _rid_of(body: Node3D) -> RID:
	if body is CollisionObject3D:
		return (body as CollisionObject3D).get_rid()
	return RID()


## The PlanetTerrain a collider belongs to, or null. Terrain collision lives on per-chunk StaticBody3D
## children of the terrain node (one shape each — see PlanetTerrain._make_chunk_collision_body), so the
## answer is up the tree, never on the body itself.
static func _terrain_of(node: Node) -> PlanetTerrain:
	var walk: Node = node
	while walk != null:
		if walk is PlanetTerrain:
			return walk as PlanetTerrain
		walk = walk.get_parent()
	return null


## Family of the biome covering `world_point`. Body-fixed direction first: the biome map is indexed by
## direction on the sphere, and the terrain node sits at the origin of its own world (see
## Server.create_planet), so the local position IS the radial.
static func _terrain_family(terrain: PlanetTerrain, world_point: Vector3) -> StringName:
	if not ("planet_data" in terrain) or terrain.planet_data == null:
		return &""
	var data = terrain.planet_data
	if not data.has_method("biome_at"):
		return &""
	var local: Vector3 = terrain.to_local(world_point)
	if local.is_zero_approx():
		return &""
	var biome = data.biome_at(local.normalized())
	if biome == null:
		return &""
	return family_of_biome(biome)


## Family of a BiomeDefinition: its own override when set, else the two-level table.
static func family_of_biome(biome) -> StringName:
	if "surface_family" in biome and not String(biome.surface_family).is_empty():
		return StringName(biome.surface_family)
	var btype: String = String(biome.biome_type) if "biome_type" in biome else ""
	if btype.is_empty():
		return &""
	var parts := btype.split("-", false, 1)
	if parts.size() == 2 and BIOME_KIND_FAMILY.has(parts[1]):
		return BIOME_KIND_FAMILY[parts[1]]
	if BIOME_CATEGORY_FAMILY.has(parts[0]):
		return BIOME_CATEGORY_FAMILY[parts[0]]
	return &""


## The material on (or under) a collider. We take the FIRST surface of the first mesh found — a prop
## you walk on or drop a crate onto is one material in practice, and picking a surface per triangle
## would need the face index the ray does not give us.
## The material of the surface AT `point` — the floor you stand on, not whichever mesh happens to
## come first in the tree.
##
## A building is dozens of meshes sharing one collision shape, so "the first one with a material"
## would cheerfully report a wall while you walk on a floor. The ray already tells us WHERE it hit, so
## we use it: among the candidates, the mesh whose bounds contain the point wins, and the smallest of
## those wins over a bigger one enclosing it (a floor slab inside a room-sized shell). Only if none
## contains it do we fall back to the nearest.
static func _material_of(node: Node, point: Vector3) -> Material:
	var best: GeometryInstance3D = null
	var best_volume: float = INF
	var nearest: GeometryInstance3D = null
	var nearest_d: float = INF
	for m in _meshes_near(node):
		var shape: GeometryInstance3D = m as GeometryInstance3D
		if _surface_material(shape) == null:
			continue  # no material to read: not a candidate at all
		# In the mesh's OWN frame: on a planet a building stands tilted to the world's axes, and a
		# world-aligned box around a 6 cm floor slab turned at 40 degrees is metres thick — it then
		# holds the point as much as the walls do, and the "smallest" was a matter of chance. The
		# margin covers the floor's top sitting a hair off the collision's.
		var local_box: AABB = _local_aabb(shape).grow(CONTAIN_MARGIN_M)
		var local_point: Vector3 = shape.global_transform.affine_inverse() * point
		if local_box.has_point(local_point):
			var scale: Vector3 = shape.global_transform.basis.get_scale()
			var size: Vector3 = local_box.size * scale
			var volume: float = size.x * size.y * size.z
			if volume < best_volume:
				best_volume = volume
				best = shape
		else:
			var d: float = (shape.global_transform * local_box.get_center()).distance_to(point)
			if d < nearest_d:
				nearest_d = d
				nearest = shape
	var chosen: GeometryInstance3D = best if best != null else nearest
	return _surface_material(chosen) if chosen != null else null


## The material a candidate surface shows: a mesh's active material, or a CSG shape's own material.
## A material_override wins on both, as it does on screen.
static func _surface_material(shape: GeometryInstance3D) -> Material:
	if shape == null:
		return null
	if shape.material_override != null:
		return shape.material_override
	if shape is MeshInstance3D:
		return (shape as MeshInstance3D).get_active_material(0)
	if shape is CSGShape3D:
		return shape.get("material") as Material
	return null


## The bounds of a candidate in its own frame. A CSG shape inside a combiner draws nothing by
## itself, so its bounds are taken from its own parameters where they are plain (box, cylinder,
## sphere), and from the engine otherwise.
static func _local_aabb(shape: GeometryInstance3D) -> AABB:
	if shape is CSGBox3D:
		var s: Vector3 = (shape as CSGBox3D).size
		return AABB(-s * 0.5, s)
	if shape is CSGCylinder3D:
		var c := shape as CSGCylinder3D
		return AABB(Vector3(-c.radius, -c.height * 0.5, -c.radius), Vector3(c.radius * 2.0, c.height, c.radius * 2.0))
	if shape is CSGSphere3D:
		var r: float = (shape as CSGSphere3D).radius
		return AABB(-Vector3.ONE * r, Vector3.ONE * r * 2.0)
	return shape.get_aabb()


## Family stated by a material's own id — `mat_<family>_<name>`.
##
## The id is looked for in the resource NAME first, and only then in the file name, because a library
## material does not always end up as a file. Godot extracts the materials of an imported GLB into a
## single .res alongside it, and there the id survives as the resource's name: the spawn houses' floor
## is mat_concrete_wall_smooth INSIDE building_apartment_001.res. Reading the path alone saw
## "building_apartment_001", found no id, and reported "unknown" for every building in the game —
## which is what made the footsteps play the error marker indoors.
##
## Empty for anything that follows neither, which is most of the older library, and says so rather
## than guessing.
static func family_of_material(mat: Material) -> StringName:
	if mat == null:
		return &""
	var family := _family_from_id(mat.resource_name)
	if family != &"":
		return family
	return _family_from_id(mat.resource_path.get_file().get_basename())


## Pull the family out of a `mat_<family>_<name>` id. Empty when the string is not one.
static func _family_from_id(id: String) -> StringName:
	if not id.begins_with(MATERIAL_ID_PREFIX):
		return &""
	var rest: String = id.substr(MATERIAL_ID_PREFIX.length())
	var cut: int = rest.find("_")
	if cut <= 0:
		return &""
	return StringName(rest.substr(0, cut))


## The meshes that belong to the SAME object as `node`, found once and remembered.
##
## Two things went wrong before this, and both are worth remembering. Climbing the tree while running
## a RECURSIVE search at every level rescanned whole subtrees several times a second — that alone sank
## the frame rate. And climbing at all eventually reached a shared ancestor, where the search happily
## returned the PLAYER'S OWN BOOTS: their bounds do contain the point under your feet, so the
## "smallest box containing the point" rule picked them, and the floor reported astronaut_boots.
##
## So: never climb past the collider's own scene instance, never cross into another physics body, and
## scan once per object rather than once per probe. The result is keyed by collider, because "which
## meshes are part of this thing" has a fixed answer for as long as the thing exists.
static var _mesh_cache: Dictionary = {}

## How far (m) outside a mesh's bounds the point under the feet still counts as on it.
const CONTAIN_MARGIN_M: float = 0.03


static func _meshes_near(node: Node) -> Array:
	if node == null:
		return []
	var key: int = node.get_instance_id()
	var cached = _mesh_cache.get(key)
	if cached != null:
		if _still_valid(cached):
			return cached
		_mesh_cache.erase(key)
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	# The collider's own subtree first: on a GLB prop the model sits right under the body.
	_collect_meshes(node, node, out)
	# Still nothing? The instance root that owns this collider — a level piece often puts the body and
	# the model side by side. Never above it: past the instance we describe the neighbours. There the
	# meshes that hang from NO body count too: a GLB's "-colonly" collisions come in as bodies BESIDE
	# its meshes (the town hall), so its floors belong to no body at all — while the player's boots or
	# a crate standing on it, under bodies of their own, stay out.
	# A CSG blockout (the village MVP placeholders): the collider IS the CSG shape that carries
	# use_collision, and its surfaces are the CSG primitives under it — no MeshInstance3D at all. Looked
	# at before the instance's bodiless meshes: a blockout's sign or lamps are not what one walks on.
	if out.is_empty() and node is CSGShape3D:
		_collect_csg_shapes(node, out)
	if out.is_empty() and node.owner != null and node.owner != node:
		_collect_meshes(node.owner, node, out, true)
	_mesh_cache[key] = out
	return out


## The CSG shapes of the blockout [param root] (itself included) that add matter: a subtracted shape
## carves a hole, it is not a surface one stands on.
static func _collect_csg_shapes(root: Node, out: Array) -> void:
	var shapes: Array[Node] = [root]
	shapes.append_array(root.find_children("*", "CSGShape3D", true, false))
	for s: Node in shapes:
		if (s as CSGShape3D).operation != CSGShape3D.OPERATION_SUBTRACTION and not out.has(s):
			out.append(s)


## Gather the meshes under `root` that still belong to `body` — anything under a DIFFERENT physics
## body is another object standing on ours, not the surface we hit. [param or_bodiless] also takes the
## meshes under no body at all (the static geometry of the collider's own instance).
static func _collect_meshes(root: Node, body: Node, out: Array, or_bodiless: bool = false) -> void:
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var owning: Node = _body_owning(m)
		if (owning == body or (or_bodiless and owning == null)) and not out.has(m):
			out.append(m)


## The physics body a node hangs from, or null. Keeps one object's meshes out of another's.
static func _body_owning(node: Node) -> Node:
	var walk: Node = node
	while walk != null:
		if walk is CollisionObject3D:
			return walk
		walk = walk.get_parent()
	return null


## True while every remembered mesh is still alive — a level piece can be freed under us.
static func _still_valid(list: Array) -> bool:
	for m in list:
		if not is_instance_valid(m):
			return false
	return true
