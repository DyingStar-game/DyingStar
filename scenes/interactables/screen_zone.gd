class_name ScreenZone
extends Area3D

## Proximity zone of a 3D screen: while the player stands in it, the mouse is freed to click the
## screen's interface and the camera faces it.
##
## PASSIVE BY DESIGN — it never looks for anybody. It only makes itself visible on the `zone` layer,
## and the player's own AreaDetector, the single active monitor of the game, reports the overlap
## (Player.connect_area_detect, Player._on_area_detector_area_entered). Seats, cargo bays, gravity and
## spawn zones all work this way; this one used to be the exception, and it was the exception that
## broke.
##
## WHY IT MATTERS, precisely: this zone hangs under a planet, and a planet SPINS in discrete steps
## (PlanetBody.rotation_update_hz, 3 Hz — about 148 m of arc per step at SandBox's surface). When the
## frame jumps, Jolt does NOT move every body at the same moment: an Area3D is repositioned at once,
## while a CharacterBody3D — the player — is a KINEMATIC body, whose new pose is merely recorded and
## only reached during the NEXT physics step. Comparing an area against the player's body therefore
## compares two different instants, and 148 m of mismatch against a 1.24 m box drops the overlap and
## regains it, once every spin step, without the player ever having moved. Comparing two AREAS of the
## same frame cannot desynchronise: both are repositioned in the same breath, whatever the spin rate.
##
## To turn any mesh into a usable screen: put this script on an Area3D covering the console, and give
## its owner an `update_screen(data)` method (the player walks up the tree looking for it). Optional:
## `screen_look_target()` to aim the camera at the screen surface rather than the object's origin, and
## `screen_focus_changed(player, focused)` to be told who is using it.


func _ready() -> void:
	# Self-configuring, like every other passive zone (VehicleSeat, VehicleDoorHandle, PlanetGravity):
	# the scene only has to place the shape, never to remember a layer number.
	collision_layer = Globals.MASK_PROBE  # the `zone` layer the player's probe scans
	collision_mask = 0  # we look for nobody
	monitoring = false
	monitorable = true
	add_to_group("screen_area")
