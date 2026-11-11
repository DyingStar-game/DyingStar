class_name MinePlacement
extends CavePlacement
## The hole a village mine's shaft opens in the ground: a round opening cut out of the terrain triangles by
## CaveTerrainCut, as a doline's oculus is, but placed by its frame (the mine's pose, from its node or its stored
## data) instead of a fitted longitude and latitude, and with nothing of a cave around it.
##
## The ground there is a building pad (MineSite's TerrainPad): flat, at the mine's own height, so the cut edge stays
## as clipped (no snap onto the relief, no refinement: CaveTerrainCut._snap and CaveRefine skip it). The concrete
## collar of the mine covers the edge.

## Corners of the cut outline. The shaft's rough wall stands within a metre of the circle anyway.
const SIDES := 32

## Planet frame of the hole: origin on the ground at the shaft's axis, +Y up the shaft.
var frame := Transform3D.IDENTITY
## Radius (m) of the hole in the ground.
var radius_m := 20.0
## Depth (m) of the shaft under the ground.
var depth_m := 250.0


static func make(id: String, mine_frame: Transform3D, radius: float, depth: float) -> MinePlacement:
    var placement := MinePlacement.new()
    placement.placement_id = id
    placement.frame = mine_frame.orthonormalized()
    placement.radius_m = radius
    placement.depth_m = depth
    return placement


func openings() -> Array[Dictionary]:
    var polygon := PackedVector2Array()
    for index in SIDES:
        var angle := TAU * index / SIDES
        polygon.append(Vector2(cos(angle), sin(angle)) * radius_m)
    var result: Array[Dictionary] = [{"kind": "skylight", "frame": frame, "polygon": polygon, "width": radius_m * 2.0,
        "length": radius_m, "back": radius_m, "floor_depth": depth_m, "primary": true, "snap": false}]
    return result


func surface_transform() -> Transform3D:
    return frame


func refines_ground() -> bool:
    return false


## The cut only: the depth changes nothing in the ground, so a hole opened from stored data (depth unknown) and the
## same hole from the live mine are one.
func signature() -> String:
    return str(["mine-hole-1", placement_id, frame, radius_m]).sha256_text().substr(0, 16)


func footprint_bounds() -> AABB:
    return frame * AABB(Vector3(-radius_m, -depth_m, -radius_m), Vector3(radius_m * 2.0, depth_m + 10.0, radius_m * 2.0))
