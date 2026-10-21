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
## Where a body that gets up stands, upright (+Y up), facing its -Z.
@export var stand_point: Marker3D

## SERVER: the player lying here, or null.
var occupant: Node = null


func _ready() -> void:
	super()
	label = "%%HUD_BED_LIE"


## The body's pose while lying here (Player._ride_bed).
func lie_transform() -> Transform3D:
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
func server_use(player: Node, _data: Dictionary) -> void:
	if player.has_method("server_toggle_lying"):
		player.server_toggle_lying(self)
