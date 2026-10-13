@tool
class_name TerrainNotch
extends TerrainPad
## Declares that the ground must be CUT here: a box notched straight down into
## the terrain, to a floor at a set depth under this node. What a vehicle lift
## needs to run down a sloped cliff — a pad levels a platform at the median of
## the relief, which on a 70° face is a shelf halfway up, not a shaft.
##
## The box starts at this node and runs [member length_m] along its local +Z,
## [member width_m] across its local X, and everything above its floor inside it
## is removed: the floor is [member floor_depth_m] under this node's origin. It
## only ever cuts: ground already lower than the floor is left alone.
##
## It is a TerrainPad in every way the terrain sees it — the same registration
## (client, server, editor), the same index, the same chunk rebuilds, the same
## refined cells (GradeRefine: walls lean over one sub-cell, ~3 m) and the same
## server surface catch — with a record of kind "notch" (PadBed.notch_record) that
## carries its own rule. It has no marker box, levels nothing, and never moves
## its building.
##
## Its whole reach must stay under half a finest HEALPix pixel (198 m on
## tarsis_3), counted from the box's CENTRE: a notch up to ~390 m long, see the
## inspector warning.

## Width (m) of the notch across this node's local X, centred on the node. It must
## clear what goes down it: a vehicle lift's lower landing is 22.2 m wide.
@export var width_m: float = 24.0:
	set(v):
		width_m = maxf(v, 0.0)
		_mark_dirty()
## Length (m) of the notch along this node's local +Z, from the node outward. 0
## cuts nothing. On a sloped cliff: how far out the slope runs before it is down
## to the floor.
@export var length_m: float = 0.0:
	set(v):
		length_m = maxf(v, 0.0)
		_mark_dirty()
## Depth (m) of the notch's floor under this node's origin. Everything above it
## inside the box is cut away; ground already lower is untouched.
@export var floor_depth_m: float = 0.0:
	set(v):
		floor_depth_m = maxf(v, 0.0)
		_mark_dirty()


func _init() -> void:
	snap_building = false  # a notch is cut under a building, it does not carry one
	apron_m = 0.0


func _persists_settled() -> bool:
	return false  # the floor is authored: nothing measured to persist


## The quantised notch record this node describes, {} when it cannot be stated.
func build_record() -> Dictionary:
	var terrain := _resolve_terrain()
	if terrain == null:
		_refusal = "aucun PlanetTerrain trouvé au-dessus de ce nœud"
		return {}
	var rel := (terrain as Node3D).global_transform.affine_inverse() * global_transform
	var rec := record_for(terrain.get("planet_data"), rel, width_m, length_m, floor_depth_m,
			_resolve_uuid(terrain))
	_refusal = str(rec.get("_refusal", ""))
	return {} if rec.has("_refusal") else rec


## The record of a notch whose node sits at [param rel] in the TERRAIN's frame. Static so the
## server can state the notch of a vehicle lift that is not in the tree (asleep, or not built yet)
## from its data, with the same numbers the live node computes. {"_refusal": why} when it cannot be
## stated.
static func record_for(data, rel: Transform3D, width: float, length: float, depth: float,
		uuid: String) -> Dictionary:
	if width <= 0.0 or length <= 0.0 or depth <= 0.0:
		return {"_refusal": "entaille vide (largeur, longueur ou profondeur nulle)"}
	if data == null:
		return {"_refusal": "le PlanetTerrain n'a pas encore de PlanetData"}
	var radius: float = float(data.radius)
	if rel.origin.length_squared() < 1.0:
		return {"_refusal": "le nœud est au centre de la planète"}
	var off := rel.origin.length() - radius
	# Before the origin-rebase reparent the node reads a position 1e10 m away: refuse, the reparent
	# calls us back with the real pose (same reason as TerrainPad.record_from).
	if absf(off) > maxf(50000.0, radius * 0.01):
		return {"_refusal": ("le nœud est à %.0f m de la surface de '%s' — il n'est pas encore "
				+ "reparenté sous la planète") % [off, data.planet_name]}
	var sr := rel.basis.get_scale()
	var centre := rel * Vector3(0.0, 0.0, 0.5 * length)
	var lonlat := HEALPix.vec2lonlat(centre.normalized())
	var lon_r := deg_to_rad(lonlat.x)
	var lat_r := deg_to_rad(lonlat.y)
	var east := Vector3(-sin(lon_r), 0.0, -cos(lon_r))
	var north := Vector3(-sin(lat_r) * cos(lon_r), cos(lat_r), sin(lat_r) * sin(lon_r))
	var x_axis := rel.basis.x.normalized()
	var yaw := atan2(x_axis.dot(north), x_axis.dot(east))
	var z_floor := off - depth * absf(sr.y)
	return PadBed.notch_record(uuid, lonlat.x, lonlat.y, yaw,
			0.5 * width * absf(sr.x), 0.5 * length * absf(sr.z), z_floor)


## Its own identity: a building may carry a TerrainPad too, under "prop:<uuid>".
func _resolve_uuid(terrain: Node) -> String:
	return "notch|" + super._resolve_uuid(terrain)


func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if width_m <= 0.0 or length_m <= 0.0 or floor_depth_m <= 0.0:
		out.append("Largeur, longueur ou profondeur nulle : cette entaille ne creuse rien.")
		return out
	var terrain := _resolve_terrain()
	if terrain == null:
		return out
	var rec := build_record()
	var data = terrain.get("planet_data")
	if rec.is_empty() or data == null:
		return out
	var side := HEALPix.pixel_side_length(1 << int(data.max_quadtree_depth), float(data.radius))
	if PadBed.reach_m(rec) > 0.5 * side:
		out.append(("La portée de l'entaille (%.0f m depuis son centre) dépasse la demi-largeur "
				+ "d'un chunk fin (%.0f m) : le terrain serait creusé par certains chunks et pas "
				+ "par leurs voisins. Raccourcissez-la.") % [PadBed.reach_m(rec), 0.5 * side])
	return out
