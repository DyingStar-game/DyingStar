class_name BedSpot
extends FurnitureTarget

## A bed the occupant of its home lies down on with the action key, and gets up from with it.
##
## Lying is a pose of the PLAYER, not a state of the building: nothing is kept across a reconnection.
## The server holds the body on [member lie_point] (Player._ride_bed), upright, and the lay emote's
## clips lay it down along the bed and stand it up again (CharacterAnimator); the first-person view
## follows the head down. One body per bed.

## Where the body stands on the mattress before the lay clip lays it down: +Y up, turned so that the
## clip puts the head on the pillow (turn it in the editor if the head lands at the foot).
@export var lie_point: Marker3D
## Where a body that gets up stands, upright (+Y up), facing its -Z: the side it gets up on first. Taken
## on the other side of the bed, or past its foot, when a wall or a piece of furniture is there
## (free_stand_transform).
@export var stand_point: Marker3D
## How far (m) past the foot of the bed -- where the lie point faces -- a body gets up when neither side
## is free.
@export_range(0.5, 3.0, 0.05) var foot_distance_m: float = 1.5

## Height (m) the body is tried at over the floor: standing on it is not touching it.
const FEET_CLEARANCE_M := 0.05

## SERVER: the player lying here, or null.
var occupant: Node = null


func _ready() -> void:
	super()
	label = "%%HUD_BED_LIE"


## The body's pose while lying here (Player._ride_bed).
func lie_transform() -> Transform3D:
	return lie_point.global_transform.orthonormalized()


## Where a body getting up stands: the first of the stand spots (stand_spots) where [param shape] -- the
## body's, [param shape_offset] above its feet -- touches no solid but the bed and [param also_ignore],
## and that the head on the pillow sees: never through the wall the bed stands against, into the next
## home (playtest 2026-10-21). On the bed when none is free.
func free_stand_transform(shape: Shape3D, shape_offset: Transform3D, also_ignore: Array) -> Transform3D:
	var ignored: Array = los_exceptions() + also_ignore
	var cast := ShapeCast3D.new()
	cast.enabled = false
	cast.top_level = true
	cast.target_position = Vector3.ZERO  # no motion: what the body overlaps where it would stand
	cast.collision_mask = Globals.MASK_OBSTACLE
	cast.max_results = 1
	cast.shape = shape
	for body in ignored:
		if body is CollisionObject3D:
			cast.add_exception(body)
	add_child(cast)
	var ray := SightLine.make_ray(self)
	var head: Vector3 = lie_transform().origin + global_basis.y * 0.3
	var chosen: Transform3D = lie_transform()
	for spot in stand_spots():
		cast.global_transform = spot.translated_local(Vector3.UP * FEET_CLEARANCE_M) * shape_offset
		cast.force_shapecast_update()
		if not cast.is_colliding() and not SightLine.blocked(ray, head, spot * Vector3.UP, ignored):
			chosen = spot
			break
	for node: Node in [cast, ray]:
		remove_child(node)
		node.free()
	return chosen


## The spots a body may get up on, best first, upright: the stand point, the same spot on the other side
## of the bed, then [member foot_distance_m] past its foot facing away from it.
func stand_spots() -> Array[Transform3D]:
	var spot: Transform3D = global_transform.orthonormalized()
	return BedSpot.spots_around(spot, spot.affine_inverse() * stand_point.global_transform.orthonormalized(),
			foot_distance_m)


## [param stand] (in the frame of the bed's [param spot]), its mirror across the bed's length (x -> -x),
## and a spot [param foot_m] past the foot (+Z), each in the world. Pure, for the tests.
static func spots_around(spot: Transform3D, stand: Transform3D, foot_m: float) -> Array[Transform3D]:
	var flip := Basis(Vector3.LEFT, Vector3.UP, Vector3.BACK)
	var mirrored := Transform3D(flip * stand.basis * flip, Vector3(-stand.origin.x, stand.origin.y, stand.origin.z))
	var foot := Transform3D(Basis(Vector3.UP, PI), Vector3(0.0, stand.origin.y, foot_m))
	return [spot * stand, spot * mirrored, spot * foot]


## Offered to the occupant of its home, hands empty, while nobody else lies here.
func usable_by(player: Node) -> bool:
	return super(player) and not ("lying_on" in player and is_instance_valid(player.lying_on))


## CLIENT: remember which bed we asked for, to ride it once the server says we lie on it.
func interact(interactor: Node = null):
	if interactor is Player and not GameOrchestrator.is_server():
		interactor.bed_asked = self
	super(interactor)


## SERVER: lie down here, or get up when already lying here.
func server_use(player: Node, _data: Dictionary) -> void:
	if player.has_method("server_toggle_lying"):
		player.server_toggle_lying(self)
