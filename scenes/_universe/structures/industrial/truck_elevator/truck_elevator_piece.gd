class_name TruckElevatorPiece
extends Node3D
## One piece of the truck elevator's model, a GLB from tools/vehicle_lift/export_truck_elevator.py under this node:
## its "Shell" (concrete, rails, road) always drawn, its "Detail" (ladders, bolts, ladder landings: most of its
## triangles) only up close, its "Collision" body (the walkable and drivable faces) solid for the world.

## Distance (m) past which the piece's details (ladders, bolts) are no longer drawn. A deep shaft stacks ~100
## sections: higher = more triangles on screen, lower = the ladders pop in closer.
@export_range(5.0, 500.0, 1.0, "suffix:m") var detail_range_m: float = 60.0


func _ready() -> void:
    for node in find_children("Detail*", "GeometryInstance3D", true, false):
        var detail := node as GeometryInstance3D
        detail.visibility_range_end = detail_range_m
        detail.visibility_range_end_margin = 4.0
        detail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    for node in find_children("*", "StaticBody3D", true, false):
        (node as StaticBody3D).collision_mask = 0  # a static body needs to meet nothing
