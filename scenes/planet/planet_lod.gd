class_name PlanetLod
extends RefCounted
## The rule that decides how finely a body's surface is cut around a camera — ONE rule, shared.
##
## [PlanetTerrain] walks its HEALPix quadtree with it, and the star chart walks the same quadtree with
## it, so a ship arriving at a planet sees the chart's ground cut the way the real ground will be.
## Before this was shared the chart spent a fixed tile budget on a single level instead: the same body
## drawn two different ways depending on which screen was looking at it.
##
## Pure arithmetic on purpose. The expressions are the ones [method PlanetTerrain._traverse] had inline,
## moved here unchanged: the chunks the game asks for, and so the meshes in its disk cache, must not
## move by a bit for having been factored out.

## Subdivide a chunk while the camera is closer than its diagonal times this.
const SUBDIVIDE_FACTOR := 1.5

## Build order, not cut: how much further a chunk or tile counts for lying away from where the camera
## looks. Straight ahead ×1, to the side ×(1 + K/2), behind ×(1 + K). The cut itself ignores the view
## direction — the ground behind stays as fine as in front, it only comes second — so turning round,
## in VR above all, never meets coarse ground refining.
const VIEW_PRIORITY_K := 3.0


## The distance factor of [constant VIEW_PRIORITY_K] for a chunk or tile whose direction from the
## camera makes [param view_dot] (cosine) with the view direction.
static func view_weight(view_dot: float) -> float:
	return 1.0 + VIEW_PRIORITY_K * (1.0 - view_dot) * 0.5


## Length of a chunk's diagonal on the reference sphere, from its SW corner to its NE corner.
static func chunk_diagonal(nside: int, ipix: int, radius: float) -> float:
	var corners: Array = HEALPix.get_pixel_corners(nside, ipix)
	var corner_a: Vector3 = corners[0] * radius  # SW
	var corner_b: Vector3 = corners[2] * radius  # NE
	return corner_a.distance_to(corner_b)


## How far a chunk is from the camera for LOD purposes: the ground distance to its centre, or the
## camera's height above the real surface, whichever is larger.
##
## Straight-line distance to the sea-level centre is wrong twice over — valleys put the camera below the
## centres, high ground inflates every distance by its elevation — so the horizontal distance is taken
## instead, and the height above the terrain alone still coarsens the view from high up.
## [param cam_dir] and [param centre_dir] are unit directions from the body's centre.
static func distance(cam_dir: Vector3, centre_dir: Vector3, radius: float,
		altitude_above_surface: float) -> float:
	var surface_dist := (cam_dir - centre_dir).length() * radius
	return maxf(surface_dist, altitude_above_surface)


## Should a chunk [param dist] away, [param chunk_diag] across, be cut into its four children? The depth
## limit is the caller's: the game and the chart stop at different depths.
static func wants_split(dist: float, chunk_diag: float) -> bool:
	return dist < chunk_diag * SUBDIVIDE_FACTOR
