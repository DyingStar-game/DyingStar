@tool
@icon("res://scenes/planet/pad/terrain_pad_icon.svg")
class_name TerrainPad
extends Node3D
## Declares that the ground under this building must be levelled.
##
## Drop one of these into a building scene with a CSGBox3D under it, size that
## box to the ground the building stands on, and the terrain answers: a level
## platform under the box, a flat apron around it to walk on and park a vehicle
## against, then a talus of a fixed, walkable slope back to the natural ground.
##
## THE BOX IS THE GROUND. Its width and length (local X and Z, scale included)
## say how much is levelled, its position and heading say where, and its TOP
## FACE says at what height — so the whole setting is done with the handles in
## the 3-D view, not by typing numbers.
##
## The top face, because that makes the box read itself: sink it until it
## vanishes into the building's floor and you KNOW the ground is below the
## floor, with no arithmetic about the box's own thickness. While any of it
## still shows, the ground is still above.
##
## And not the node's origin, because a building's floor is a SLAB: the cargo
## depot's is 1 m thick with its top at y = 0, so levelling to the origin puts
## the terrain in the very plane the player walks on and buries the slab whole.
##
## The box is an editor marker, never game geometry: outside the editor
## TerrainPad reads it once and frees it, so nothing of it reaches a build.
##
## The node is the AUTHORING surface and nothing else. Everything the geometry
## depends on is flattened into a quantised pad record (see PadBed) the moment
## the pad is registered, so the mesh workers, the collision builder and the
## server's surface catch never touch a node — and a client and a server that
## disagree about a float in the last bit still build the same ground.
##
## It registers itself, which is what makes the three cases the design has to
## cover fall out of one mechanism: a building placed in the editor, a building
## instanced by the server, and a building created by the client when it enters
## GORC range all instance this same scene, so all three end up in the index.
##
## The altitude is NOT authored: the platform sits at the median of the relief
## under the footprint, so a building that spawns at runtime — where no designer
## is there to place it — levels its ground by the same rule as one placed by
## hand. [member height_offset] shifts it when you want it higher or lower.

## Name of the child CSGBox3D that marks the footprint. Any CSGBox3D under this
## node is used when none carries this name, so an existing scene does not have
## to be renamed to work.
const BOX_NAME := "Ground"

## How far the FLAT apron reaches past the box, in metres. This is the ground a
## player walks on and a truck parks on, so it is level with the building's
## floor; the talus only starts beyond it. It is a number and not part of the
## box because it says something different — the box is what the BUILDING
## covers, the apron is the room to move around it.
@export var apron_m: float = PadSettings.APRON_M:
	set(v):
		apron_m = maxf(v, 0.0)
		_mark_dirty()

## Raises (+) or lowers (−) the platform against the median it would sit at.
@export var height_offset: float = 0.0:
	set(v):
		height_offset = v
		_mark_dirty()

## Sit the building down ON the platform the pad levelled.
##
## The platform is at the MEDIAN of the relief under the footprint, which is
## not the relief at the building's own origin — so a building placed before
## the pad existed keeps its old altitude and floats above the platform or
## sinks into it. In the editor you fix that with Planet Tools ▸ Snap to planet
## surface; at runtime nobody does, and a building streamed in by Horizon
## carries a pose stored long before any pad existed. The SERVER therefore
## corrects it once, radially, and replicates the corrected pose like any other
## movement — so the fix reaches every client and is persisted.
##
## Turn it off for a building that is MEANT to stand off its platform (one on
## stilts, a gantry): the pad still levels the ground, the building stays put.
@export var snap_building := true:
	set(v):
		snap_building = v
		_mark_dirty()

## A correction smaller than this is not worth a network update.
const SNAP_EPSILON_M := 0.05
## Nor is a tilt smaller than this. A building is LONG: over the 97 m of a
## cargo depot, one degree of tilt buries one end by 1.7 m while its origin
## sits perfectly on the platform — which is why the altitude alone is not
## "snapped to the surface", and why the gap printed at the origin can read
## +0.01 m while the far end is metres into the ground.
const SNAP_EPSILON_DEG := 0.05

## Turn the pad off without deleting the node — the terrain goes back to its
## natural relief on the next chunk rebuild.
@export var enabled: bool = true:
	set(v):
		enabled = v
		_mark_dirty()

## The terrain this pad is registered with, and under which uuid.
var _terrain: Node = null
var _uuid: String = ""
var _dirty := false
## The box's size and its transform RELATIVE TO THIS NODE, cached so the
## record can still be built after the marker has been freed at runtime.
var _box_size := Vector3.ZERO
var _box_local := Transform3D.IDENTITY
var _box_read := false
## Why the last build_record() refused, and the last line printed — a pad is
## silent once it has said its piece, because a transform notification fires
## for every motion of every ancestor and would otherwise repeat it forever.
var _refusal := ""
var _said := ""


## Registration hangs off ENTER_TREE, not _ready, because a networked prop is
## REPARENTED: PropSync.client_parent_change / server_parent_change call
## Node.reparent(), which fires _exit_tree then _enter_tree — and _ready does
## NOT run a second time. Registering in _ready meant the pad was unregistered
## by the reparent and never came back, so a building streamed in by Horizon
## levelled nothing. Entering the tree is also the first moment the transform
## is meaningful: both spawn paths (server/server.gd, server/client.gd) apply
## the pose with client_channel_data_update BEFORE add_child, on purpose.
func _enter_tree() -> void:
	set_notify_transform(true)
	if not Engine.is_editor_hint():
		# Read the marker once, then drop it: a CSGBox3D is a mesh generator,
		# and this one exists only to be dragged in the editor. On a later
		# re-entry it is already gone and the cached reading answers.
		_read_box()
		var box := _find_box()
		if box != null:
			box.queue_free()
	_mark_dirty()


func _exit_tree() -> void:
	_unregister()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		# Fires for every motion of every ancestor, the planet's own spin
		# included. The record is stated in the body-fixed frame, so a spin
		# produces an identical record and PadIndex.register answers "nothing
		# changed" — but only after we have rebuilt it, hence the debounce.
		_mark_dirty()


func _mark_dirty() -> void:
	if _dirty or not is_inside_tree():
		return
	_dirty = true
	_apply.call_deferred()


## Register the pad NOW, on this thread, instead of on the next frame.
## PlanetTerrain calls it during its warm-up so the pads of the buildings
## already in the scene are in the index before the first chunk is built.
func register_now() -> void:
	_dirty = false
	_apply()


func _apply() -> void:
	_dirty = false
	if not is_inside_tree():
		return
	var terrain := _resolve_terrain()
	if terrain == null:
		return
	if terrain != _terrain:
		_unregister()
		_terrain = terrain
	if not enabled:
		_unregister()
		return
	var rec := build_record()
	if rec.is_empty():
		_say("pas de pad : %s" % _refusal)
		return
	var uuid := str(rec["uuid"])
	if not _uuid.is_empty() and _uuid != uuid:
		_unregister()
	_uuid = uuid
	terrain.register_terrain_pad(rec)
	var z: float = terrain.terrain_pad_altitude(rec)
	var what := "emprise %.1f × %.1f m + %.0f m de tablier" % [
			2.0 * float(rec["hx"]), 2.0 * float(rec["hy"]), float(rec["apron_m"])]
	if is_nan(z):
		# Not levelled anything yet: the elevation tiles under the footprint are
		# not readable, so the platform has no altitude and the pad is set aside
		# until they arrive (PlanetData.retry_starved_pads).
		_say("pad '%s' EN ATTENTE des tuiles d'élévation — %s" % [uuid, what])
		return
	# The gap is the thing to look at when a building looks wrong: the platform
	# sits at the MEDIAN of the relief under the footprint, which is not the
	# relief at the building's own origin. A building placed before the pad
	# existed — in the editor, or by Horizon from a stored pose — keeps that old
	# altitude and ends up floating above its platform or sunk into it. Re-snap
	# it (Planet Tools ▸ Snap to planet surface) when this is more than a step.
	var own := _own_altitude(terrain)
	var tilt := _own_tilt_deg(terrain)
	# lon/lat and the finest pixel are printed so test/parity/pad_probe.tscn can
	# be pointed at this exact spot (PAD_PROBE_LONLAT) and reproduce the chunk
	# offline, which is the only way to tell a bad rule from a bad LOD.
	var finest: int = 1 << int(terrain.planet_data.max_quadtree_depth)
	_say("pad '%s' : %s, plateau à %.1f m, bâtiment à %.1f m (écart %+.2f m, inclinaison %.2f° → %+.2f m au bout) — lon %.5f lat %.5f, n%d p%d" % [
			uuid, what, z, own, own - z, tilt, _tilt_drop_m(tilt, rec),
			float(rec["lon"]), float(rec["lat"]), finest,
			HEALPix.vec2pix_nest(finest, HEALPix.lonlat2vec(float(rec["lon"]), float(rec["lat"])))])
	if snap_building and bool(terrain.get("is_server")) and not Engine.is_editor_hint():
		# Orientation FIRST: straightening a tilted building moves its origin,
		# so the altitude must be measured after, not before.
		_align_building_to_surface(terrain)
		_sit_building_on_platform(terrain, z)


## Move the building radially so THIS node lands on the platform. Server only:
## the server owns a networked prop's pose, and PropNet replicates the change
## like any other movement, so every client converges and Horizon persists it.
## Idempotent — the move fires a transform notification, we are called back,
## and the second pass finds nothing left to correct.
func _sit_building_on_platform(terrain: Node, z: float) -> void:
	var delta := z - _own_altitude(terrain)
	if is_nan(delta) or absf(delta) < SNAP_EPSILON_M:
		return
	var body := _building_root()
	# Only a building standing directly ON the body: never something riding a
	# vehicle or held by a player, whose pose belongs to its carrier.
	if body == null or not (body.get_parent() is Planet):
		return
	var pxf := (terrain as Node3D).global_transform
	var local := pxf.affine_inverse() * body.global_position
	if local.length_squared() < 1.0:
		return
	body.global_position = pxf * (local + local.normalized() * delta)
	print("[TerrainPad] bâtiment '%s' reposé sur son plateau (%+.2f m)" % [_uuid, delta])


## The prop this pad belongs to: the outermost node under the planet, which is
## what the network addresses and what must move as one piece.
func _building_root() -> Node3D:
	var n: Node3D = self
	for _i in 8:
		var p := n.get_parent()
		if p == null or not (p is Node3D) or p is Planet or p is PlanetTerrain:
			return n
		n = p as Node3D
	return n


## Angle, in degrees, between the building's own "up" and the body's radial
## direction under it. Zero when the building stands square on the surface.
func _own_tilt_deg(terrain: Node) -> float:
	var body := _building_root()
	if body == null:
		return NAN
	var pxf := (terrain as Node3D).global_transform
	var inv := pxf.affine_inverse()
	var local := inv * body.global_position
	if local.length_squared() < 1.0:
		return NAN
	var up := local.normalized()
	return rad_to_deg((inv.basis * body.global_transform.basis).y.normalized().angle_to(up))


## How far a tilt of [param tilt_deg] lifts or buries the far end of a pad
## this long — the number that says whether a tilt matters.
func _tilt_drop_m(tilt_deg: float, rec: Dictionary) -> float:
	if is_nan(tilt_deg):
		return NAN
	return tan(deg_to_rad(tilt_deg)) * maxf(float(rec["hx"]), float(rec["hy"]))


## Stand the building square on the surface: its +Y along the local radial,
## its heading (−Z projected on the tangent plane) preserved, its scale kept.
## The same rule as PlanetTerrain.compute_surface_transform, which is what the
## editor's Snap to planet surface applies — a networked building never gets
## it, because Horizon replays whatever pose was stored for it.
func _align_building_to_surface(terrain: Node) -> void:
	var tilt := _own_tilt_deg(terrain)
	if is_nan(tilt) or tilt < SNAP_EPSILON_DEG:
		return
	var body := _building_root()
	if body == null or not (body.get_parent() is Planet):
		return
	var pxf := (terrain as Node3D).global_transform
	var inv := pxf.affine_inverse()
	var up := (inv * body.global_position).normalized()
	var b := inv.basis * body.global_transform.basis
	var gscale := b.get_scale()
	var z_axis := b.z - up * b.z.dot(up)
	if z_axis.length_squared() < 1e-9:
		z_axis = up.cross(Vector3.RIGHT)
		if z_axis.length_squared() < 1e-9:
			z_axis = up.cross(Vector3.BACK)
	z_axis = z_axis.normalized()
	var x_axis := up.cross(z_axis).normalized()
	z_axis = x_axis.cross(up).normalized()
	body.global_transform = Transform3D(
			pxf.basis * Basis(x_axis, up, z_axis).scaled(gscale), body.global_position)
	print("[TerrainPad] bâtiment '%s' redressé sur la normale (%.2f°)" % [_uuid, tilt])


## The world point that must end up ON the platform: the centre of the box's
## TOP face. Everything that positions the building — the editor snap, the
## server's re-seating, the gap printed in the log — measures here, so they all
## agree on what "the building meets the ground" means, and so the box stays
## readable at a glance: no box in sight, ground under the floor.
func ground_reference_global() -> Vector3:
	if not _read_box():
		return global_position
	return global_transform * (_box_local * Vector3(0.0, 0.5 * _box_size.y, 0.0))


## The altitude of [method ground_reference_global] above the body radius.
func _own_altitude(terrain: Node) -> float:
	var data = terrain.get("planet_data")
	if data == null:
		return NAN
	var local: Vector3 = (terrain as Node3D).global_transform.affine_inverse() \
			* ground_reference_global()
	return local.length() - float(data.radius)


## Say [param msg] once. What a pad did — or why it did nothing — is the first
## thing to look for when a building stands on unlevelled ground, and there are
## a handful of pads per body, so this is cheap enough to always be on.
func _say(msg: String) -> void:
	if msg == _said:
		return
	_said = msg
	print("[TerrainPad] %s (%s)" % [msg, get_path() if is_inside_tree() else name])


func _unregister() -> void:
	if _terrain != null and not _uuid.is_empty() and is_instance_valid(_terrain):
		_terrain.unregister_terrain_pad(_uuid)
	_uuid = ""


## The quantised pad record this node describes, {} when it cannot be stated
## (no terrain, no box, or the node sits at the planet centre).
func build_record() -> Dictionary:
	var terrain := _resolve_terrain()
	if terrain == null:
		_refusal = "aucun PlanetTerrain trouvé au-dessus de ce nœud"
		return {}
	if not _read_box():
		_refusal = "aucun CSGBox3D enfant, ou boîte plate en X ou en Z"
		return {}
	# Everything is taken from the BOX, not from this node: the box is what the
	# designer drags, and this node may sit anywhere convenient in the building.
	var box_world := global_transform * _box_local
	# The record is body-fixed: the heightmap is indexed by local direction, and
	# the body is rotated by its spin, by a system scene's tilt and by the
	# editor's "fly in planet frame". Stating the pad in world space would read
	# the altitude of some other point of the planet — the same trap
	# PlanetTerrain.compute_surface_transform documents.
	var inv := (terrain as Node3D).global_transform.affine_inverse()
	var local_pos := inv * box_world.origin
	if local_pos.length_squared() < 1.0:
		_refusal = "le nœud est au centre de la planète"
		return {}
	# A building must stand ON the body. The server spawns a prop whose
	# parent_id is empty in TRUE universe coordinates and only rebases it into
	# the owning planet afterwards ("ORIGIN REBASE" in server/server.gd), and
	# the client sees the same prop under universe_scene for a moment before
	# Horizon's parent change arrives. Registering then would read a longitude
	# and latitude off a position 1e10 m away and level a patch of ground
	# somewhere else entirely. Refusing here costs nothing: the reparent fires
	# ENTER_TREE again and we are called back with the real pose.
	var data = terrain.get("planet_data")
	if data == null:
		_refusal = "le PlanetTerrain n'a pas encore de PlanetData"
		return {}
	var radius: float = float(data.radius)
	var off := local_pos.length() - radius
	if absf(off) > maxf(50000.0, radius * 0.01):
		_refusal = ("le bâtiment est à %.0f m de la surface de '%s' — il n'est pas "
				+ "encore reparenté sous la planète") % [off, data.planet_name]
		return {}
	_refusal = ""
	var lonlat := HEALPix.vec2lonlat(local_pos.normalized())
	var lon_r := deg_to_rad(lonlat.x)
	var lat_r := deg_to_rad(lonlat.y)
	var east := Vector3(-sin(lon_r), 0.0, cos(lon_r))
	var north := Vector3(-sin(lat_r) * cos(lon_r), cos(lat_r), -sin(lat_r) * sin(lon_r))
	var x_axis := (inv.basis * box_world.basis.x).normalized()
	var yaw := atan2(x_axis.dot(north), x_axis.dot(east))
	var half := footprint_half_extents()
	return PadBed.record(_resolve_uuid(terrain), lonlat.x, lonlat.y, yaw,
			half.x, half.y, apron_m, height_offset)


## Half the levelled footprint in metres, as the box currently measures it:
## .x across the box's local X, .y across its local Z, the scale it stands
## under included. Vector2.ZERO when there is no usable box. This is what the
## record is built from, so it is also what to print when a pad looks wrong.
func footprint_half_extents() -> Vector2:
	if not _read_box():
		return Vector2.ZERO
	var sc := _box_local.basis.get_scale()
	if is_inside_tree():
		var g := global_transform.basis.get_scale()
		sc = Vector3(sc.x * g.x, sc.y * g.y, sc.z * g.z)
	return Vector2(0.5 * _box_size.x * absf(sc.x), 0.5 * _box_size.z * absf(sc.z))


## The CSGBox3D that marks the footprint: the one named [constant BOX_NAME] if
## there is one, else the first CSGBox3D under this node.
func _find_box() -> CSGBox3D:
	var named := get_node_or_null(NodePath(BOX_NAME))
	if named is CSGBox3D:
		return named as CSGBox3D
	for child: Node in get_children():
		if child is CSGBox3D:
			return child as CSGBox3D
	return null


## Refresh [member _box_size] / [member _box_local] from the marker. In the
## editor it is re-read every time, so dragging a handle moves the ground; at
## runtime the marker is already gone and the cache is the answer.
func _read_box() -> bool:
	var box := _find_box()
	if box != null:
		_box_size = box.size
		# The marker is always a DIRECT child (see _find_box), so its own
		# transform already is the pad-relative one. Deliberately not
		# box.global_transform: _read_box runs from _enter_tree, and a child
		# has not entered the tree yet when its parent does — asking a node
		# outside the tree for a global transform is an error.
		_box_local = box.transform
		_box_read = true
	return _box_read and _box_size.x > 0.0 and _box_size.z > 0.0


## The altitude (metres above the radius) this pad levels the ground to, or
## NAN while the elevation tiles under it are not readable yet. The editor snap
## and the building's own placement both come through here.
func pad_altitude() -> float:
	var terrain := _resolve_terrain()
	if terrain == null:
		return NAN
	var rec := build_record()
	if rec.is_empty():
		return NAN
	return terrain.terrain_pad_altitude(rec)


## A stable identity for this pad, the same string on the client and on the
## server. The networked uuid when the building has one — it is assigned by
## Horizon and both machines see it — and otherwise the path from the body,
## which is identical in both builds for anything placed in the scene.
func _resolve_uuid(terrain: Node) -> String:
	# No networked identity in the editor: there, the scene path IS the identity,
	# and it is the same string in the client and the server builds.
	if not Engine.is_editor_hint():
		var n: Node = get_parent()
		while n != null and n != terrain and not (n is PlanetTerrain):
			var sync := PropSync.of(n)
			if sync != null and not sync.uuid.is_empty():
				return "prop:" + sync.uuid
			n = n.get_parent()
	var root: Node = terrain.get_parent() if terrain.get_parent() != null else terrain
	return "scene:" + str(root.get_path_to(self))


## The PlanetTerrain this pad stands on: the one owned by the nearest Planet
## ancestor, or — for a prop the network parented elsewhere — the live body
## whose surface the pad is actually sitting on.
func _resolve_terrain() -> Node:
	var n: Node = get_parent()
	while n != null:
		if n is PlanetTerrain:
			return n
		if n is Planet and (n as Planet).planet_terrain != null:
			return (n as Planet).planet_terrain
		for child in n.get_children():
			if child is PlanetTerrain:
				return child
		n = n.get_parent()
	return _nearest_terrain()


func _nearest_terrain() -> Node:
	# PlanetRegistry reads the network registry, which does not exist in the
	# editor — and there a pad is always a descendant of its own Planet, so the
	# ancestor walk above has already answered.
	if Engine.is_editor_hint():
		return null
	var best: Node = null
	var best_err := INF
	for body in PlanetRegistry.live_planets():
		var terrain = body.get("planet_terrain")
		if terrain == null or body.planet_data == null:
			continue
		var err := absf(global_position.distance_to((body as Node3D).global_position)
				- body.planet_data.radius)
		if err < best_err:
			best_err = err
			best = terrain
	return best


func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if _find_box() == null:
		out.append(("Ajoutez un CSGBox3D enfant (nommez-le « %s ») : c'est lui qui "
				+ "dessine le sol à aplanir. Sans lui ce pad n'aplanit rien.") % BOX_NAME)
		return out
	if not _read_box():
		out.append("La boîte est plate en X ou en Z : le terrain ne sera pas aplani.")
		return out
	var terrain := _resolve_terrain()
	# No terrain in the editor is the normal case for a building scene edited on
	# its own: it only meets its planet once instanced (_nearest_terrain), so the
	# terrain-dependent checks below are simply skipped, not an error.
	if terrain == null:
		return out
	var rec := build_record()
	if rec.is_empty():
		return out
	var data = terrain.get("planet_data")
	if data == null:
		return out
	var side := HEALPix.pixel_side_length(1 << int(data.max_quadtree_depth), float(data.radius))
	if PadBed.reach_m(rec) > 0.5 * side:
		out.append(("La portée du pad (%.0f m) dépasse la demi-largeur d'un chunk fin "
				+ "(%.0f m) : le terrain serait aplani par certains chunks et pas par "
				+ "leurs voisins.") % [PadBed.reach_m(rec), 0.5 * side])
	var z: float = terrain.terrain_pad_altitude(rec)
	if not is_nan(z):
		var span: float = terrain.terrain_pad_height_span(rec)
		if span / PadSettings.TALUS_SLOPE > PadSettings.TALUS_MAX_M:
			out.append(("Le terrain varie de %.0f m sous ce pad : le talus est écrêté à "
					+ "%.0f m et laisse une marche. Déplacez le bâtiment sur un terrain "
					+ "moins pentu ou réduisez son emprise.") % [span, PadSettings.TALUS_MAX_M])
	return out
