@tool
class_name VehicleLiftModel
extends Resource
## The parts and measures of one vehicle lift model: VehicleLift builds and drives any of them with the same
## code. vehicle_lift_model_a.tres is the first lift (winch, landings with bridges, 3 m rail segments);
## truck_elevator_model.tres the concrete tower whose platform hangs in front (10 m sections, built from the top).
##
## A part left empty is not built, and nothing is asked of it (no winch, no rail head, no bridges...).

@export_group("Parts")
## The winch at the top (base/base.gd: set_axis_length, update_animated_axis_rotation). Empty = none.
@export var base_scene: PackedScene
## The landing at the top (a LiftLanding with is_upper), at the lift's origin moved out by guide_z_offset.
@export var upper_landing_scene: PackedScene
## The landing at the foot (a LiftLanding), descent_depth under the top, moved by lower_landing_offset.
@export var lower_landing_scene: PackedScene
## The landing of each stop (VehicleLift.stop_depths), a LiftLanding. Empty = the upper landing's scene.
@export var stop_landing_scene: PackedScene
## The top of the guide (a StaticBody3D). Empty = none.
@export var rail_head_scene: PackedScene
## One length of the guide, repeated down the run (segment_height_m apart).
@export var rail_segment_scene: PackedScene
## The bridges from the edge to the guide, stretched by guide_z_offset (dynamic_bridges.gd). Empty = none.
@export var dynamic_bridges_scene: PackedScene
## The networked platform system (prop vehicle_lift_platformsystem) the server spawns under the lift.
@export var platform_system_scene: PackedScene

@export_group("Measures")
## Where the platform system stands (m, lift frame) with the platform at the top, before guide_z_offset.
@export var platform_system_offset: Vector3 = Vector3(0.0, -0.175, 2.075)
## Where the lower landing stands (m) from the foot of the run (descent_depth under the top, guide_z_offset out).
@export var lower_landing_offset: Vector3 = Vector3.ZERO
## How much higher (m) the platform stops at the intermediate stops (VehicleLift.stop_depths), to stand level with
## their floors: raise it if the deck stops under them, lower it if above. Taken up over the first
## VehicleLift.STOP_RAISE_RAMP_M of the run: the upper landing keeps its exact height.
@export_range(-2.0, 2.0, 0.01, "suffix:m") var stop_raise_m: float = 0.0
## How much higher (m) the platform stops at the foot (the lower landing), where it may rest on a slab of its own
## (the truck elevator's pit): raise it if the deck stops under that floor, lower it if above. Taken up over the last
## VehicleLift.STOP_RAISE_RAMP_M of the run.
@export_range(-2.0, 2.0, 0.01, "suffix:m") var foot_raise_m: float = 0.0
## Height (m) of one rail segment: one more segment every this much descent.
@export_range(0.5, 50.0, 0.01, "suffix:m") var segment_height_m: float = 3.0
## Depth (m) under the top where the first segment starts: what the upper landing's own part of the guide covers.
@export_range(0.0, 50.0, 0.01, "suffix:m") var segment_top_m: float = 0.0
## Height (m) of the guide the lower landing carries itself, above the foot: the segments stop there (the last
## one sinks into it rather than being cut).
@export_range(0.0, 50.0, 0.01, "suffix:m") var segment_bottom_m: float = 0.0
## Where a segment's origin is (m) under its top: half its height for a segment centred on its origin, 0 for one
## hanging from its top.
@export_range(0.0, 50.0, 0.01, "suffix:m") var segment_origin_m: float = 1.5
## Segments added past those the descent needs (the first lift draws one more than it covers).
@export_range(0, 4) var segment_extra: int = 1
## Size (m) of the guide's collision box across (x) and out from the wall (z); its height follows the segments.
@export var rail_collider_size: Vector2 = Vector2(2.67, 0.5)
## Centre (m) of that box across (x) and out (z), from the guide.
@export var rail_collider_center: Vector2 = Vector2(0.0, 2.25)


## How many rail segments a run [param descent_m] deep needs (a millimetre over a whole number of segments is not
## one more: the float sum of the measures is not exact).
func segment_count(descent_m: float) -> int:
	var span := descent_m - segment_top_m - segment_bottom_m - 0.001
	return maxi(ceili(span / segment_height_m), 0) + segment_extra


## Height (m, lift frame, negative down) of the origin of segment [param index].
func segment_y(index: int) -> float:
	return -(segment_top_m + index * segment_height_m + segment_origin_m)
