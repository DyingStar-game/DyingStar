extends Interactable

## PASSIVE BY DESIGN, like ScreenZone / VehicleSeat / VehicleDoorHandle: a look-at target for the
## player's InteractRay, which calls interact() on what it hits. It is DETECTED; it never detects.
##
## It used to carry none of this, so it inherited the engine defaults — layer 1 and mask 1 — and two
## things followed. It queried the whole `world` layer (planet terrain, ~4800 shapes) on every
## physics step for nothing, the cost measured at ~6 ms/tick per area far from the world origin. And
## sitting on `world` rather than `interactable`, it was invisible to the InteractRay (mask 32), so
## the kiosk could not in fact be used at all.
##
## It is an Interactable now — the layers, interact() and the HUD prompt (`label`) all come from there,
## and the player's `action` key only ever presses an Interactable (PlayerClient._aimed_interactable).
