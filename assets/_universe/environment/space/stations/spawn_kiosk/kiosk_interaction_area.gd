extends Area3D

## PASSIVE BY DESIGN, like ScreenZone / VehicleSeat / VehicleDoorHandle: a look-at target for the
## player's InteractRay, which calls interact() on what it hits. It is DETECTED; it never detects.
##
## It used to carry none of this, so it inherited the engine defaults — layer 1 and mask 1 — and two
## things followed. It queried the whole `world` layer (planet terrain, ~4800 shapes) on every
## physics step for nothing, the cost measured at ~6 ms/tick per area far from the world origin. And
## sitting on `world` rather than `interactable`, it was invisible to the InteractRay (mask 32), so
## the kiosk could not in fact be used at all.

signal interacted()

@export var label = "Interact"


func _ready() -> void:
	# Self-configuring: the scene only has to place the shape, never remember a layer number.
	collision_layer = 1 << (Globals.LAYER_INTERACTABLE - 1)
	collision_mask = 0  # we look for nobody
	monitoring = false
	monitorable = true

func interact(interactor: Node = null) -> void:
	emit_signal("interacted", interactor)
