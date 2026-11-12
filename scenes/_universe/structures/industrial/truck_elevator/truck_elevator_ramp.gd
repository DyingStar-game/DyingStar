class_name TruckElevatorRamp
extends AnimatableBody3D
## The front ramp of the truck elevator's platform, hinged on the deck's front edge: folded up (a barrier across the
## way out) while the lift runs and at the top (its front faces the shaft there), laid down onto the landing when it
## stops at a level or at the bottom. Driven by the lift's replicated state
## (VehicleLift.is_moving), so the server's collision and every client's ramp move alike. One box of collision, which
## turns with it.
##
## Two rules keep it off what it carries (playtest 2026-11-11, a truck shaking and knocked crooked going down):
## - it never touches its own platform: a kinematic body overlapping the deck pushed it, the deck carried it along,
##   and the push never ended (collision exception);
## - the lift waits for it to be folded before it moves (VehicleLift reads holds_departure), and on the server it
##   does not fold onto a vehicle, a player or a load standing in its way: it waits until they are clear. That wait
##   is replicated (VehicleLift.departure_blocked), so every client's ramp waits with the server's.

## The space the ramp sweeps as it folds, in the hinge's frame: across the deck, from just behind the hinge (its
## thickness when upright) to its tip, from the deck up to its height upright (m).
const SWEEP_CENTER := Vector3(-0.074, 0.62, 0.59)
const SWEEP_SIZE := Vector3(9.0, 1.35, 1.42)
## Layers of what the ramp must not fold onto: players, vehicles, props.
const SWEEP_MASK := 14
## From the hinge to the ramp's tip (m), and how far under the floor its tip is laid (m, the deck sags a few
## centimetres on its spring under a load): the angle that reaches a floor the deck stands above (laid_angle).
const REACH_M := 1.25
const TIP_DIP_M := 0.03

## Angle (deg) of the ramp folded up: -90 = upright, its tip straight above the hinge.
@export_range(-120.0, 0.0, 1.0, "suffix:deg") var folded_deg: float = -90.0
## Angle (deg) of the ramp laid down with the deck level with the landing: positive tips it down onto the floor.
## Where the deck stands higher (VehicleLift.deck_raise: at the foot, on the pit's slab), it tips further by itself
## to reach the floor. Higher = a steeper ramp.
@export_range(0.0, 30.0, 0.5, "suffix:deg") var laid_deg: float = 5.0
## Time (s) the ramp takes to fold up or lay down. Lower = snappier.
@export_range(0.1, 10.0, 0.1, "suffix:s") var fold_time_s: float = 1.5

var _lift: VehicleLift = null
var _sweep_shape := BoxShape3D.new()
var _sweep_query := PhysicsShapeQueryParameters3D.new()


func _ready() -> void:
	sync_to_physics = false
	_lift = _find_lift()
	add_to_group(VehicleLift.DEPARTURE_GATE_GROUP)
	var platform := get_parent() as PhysicsBody3D
	if platform != null:
		add_collision_exception_with(platform)
	_sweep_shape.size = SWEEP_SIZE
	_sweep_query.shape = _sweep_shape
	_sweep_query.collision_mask = SWEEP_MASK
	_sweep_query.collide_with_areas = false


func _physics_process(delta: float) -> void:
	if not is_instance_valid(_lift):
		_lift = _find_lift()
		if _lift == null:
			return
	var target := deg_to_rad(folded_deg) if _wants_folded() else laid_angle(_lift.deck_raise(), laid_deg)
	var arrived := is_equal_approx(rotation.x, target)
	# Something stands where it would fold: wait, and the lift waits for it. The server looks and says so
	# (replicated through the lift), each client's ramp waits on its word.
	var blocked := false
	if not arrived and _wants_folded():
		blocked = _sweep_blocked() if GameOrchestrator.is_server() else _lift.departure_blocked()
	if GameOrchestrator.is_server():
		_lift.set_departure_blocked(blocked)
	if arrived or blocked:
		return
	var step := absf(deg_to_rad(laid_deg - folded_deg)) / maxf(fold_time_s, 0.01) * delta
	rotation.x = move_toward(rotation.x, target, step)


## The ramp's laid angle (rad): [param min_deg], or steeper to reach a floor [param raise_m] (m) under the deck.
## Static and pure.
static func laid_angle(raise_m: float, min_deg: float) -> float:
	var reach := asin(clampf((raise_m + TIP_DIP_M) / REACH_M, 0.0, 0.7))
	return maxf(deg_to_rad(min_deg), reach)


## SERVER, read by VehicleLift before it moves off: true while the ramp should be folded and is not yet.
func holds_departure() -> bool:
	return _wants_folded() and not is_equal_approx(rotation.x, deg_to_rad(folded_deg))


func _wants_folded() -> bool:
	return _lift != null and (_lift.is_moving() or _lift.at_top())


## A player, a vehicle or a load in the space the ramp sweeps (not the platform, its system, nor the ramp).
func _sweep_blocked() -> bool:
	var platform := get_parent() as CollisionObject3D
	if platform == null:
		return false
	var excluded: Array[RID] = [get_rid(), platform.get_rid()]
	var carrier := platform.get_parent() as CollisionObject3D
	if carrier != null:
		excluded.append(carrier.get_rid())
	_sweep_query.exclude = excluded
	_sweep_query.transform = platform.global_transform * Transform3D(Basis.IDENTITY, position + SWEEP_CENTER)
	for hit: Dictionary in get_world_3d().direct_space_state.intersect_shape(_sweep_query, 8):
		var body: Object = hit.get("collider")
		if body is Player or body is Vehicle or (body is RigidBody3D and "uuid" in body):
			return true
	return false


## The lift this ramp's platform belongs to (platform -> platform system -> lift).
func _find_lift() -> VehicleLift:
	var at := get_parent()
	while at != null and not at is VehicleLift:
		at = at.get_parent()
	return at as VehicleLift
