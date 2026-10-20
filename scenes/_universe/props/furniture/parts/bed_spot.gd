class_name BedSpot
extends FurnitureTarget

## A bed the occupant of its home lies down on with the action key, and gets up from with it.
##
## Lying is a pose of the PLAYER, not a state of the building: nothing is kept across a reconnection.
## The server rides the body on [member lie_point] (PlayerServer.server_toggle_lying, the seat ride of
## Player._ride_seat): the whole body is laid along the bed, its eyes looking at the ceiling, so the
## first-person view looks up and the others see the body lying -- with no clip of its own. One body
## per bed.

## The eyes of the body lying here: +Y towards the pillow (the head), -Z up (where the eyes look).
@export var lie_point: Marker3D
## Where a body that gets up stands, upright (+Y up), facing its -Z.
@export var stand_point: Marker3D

## SERVER: the player lying here, or null.
var occupant: Node = null


func _ready() -> void:
	super()
	label = "%%HUD_BED_LIE"


## The eye pose the body rides while lying here (what a seat's sit_transform is to Player._ride_seat).
func sit_transform() -> Transform3D:
	return lie_point.global_transform.orthonormalized()


## Offered to the occupant of its home, hands empty, while nobody else lies here.
func usable_by(player: Node) -> bool:
	return super(player) and not ("lying_on" in player and is_instance_valid(player.lying_on))


## CLIENT: remember which bed we asked for, to ride it once the server says we lie on it.
func interact(interactor: Node = null):
	if interactor is Player and not GameOrchestrator.is_server():
		interactor.bed_asked = self
	super(interactor)


## SERVER: lie down here, or get up when already lying here.
func server_use(player: Node) -> void:
	if player.has_method("server_toggle_lying"):
		player.server_toggle_lying(self)
