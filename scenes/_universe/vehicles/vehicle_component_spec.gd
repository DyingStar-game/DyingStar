@tool
class_name VehicleComponentSpec
extends Resource

## What a vehicle component IS, independent of any scene: the data a part carries around.
## A part lying in the world (a carried prop) points at one of these, and a slot on a vehicle
## accepts one kind of them. Adding a new component TYPE (battery, tank) is a new subclass plus
## a .tres — no change to the vehicle code.
##
## Same split as ElevatorKit / CsgElevatorKit: a Resource DESCRIBES, a Node assembles.
##
## @tool is NOT decoration here. Without it the resource is instantiated as a PLACEHOLDER in the
## editor: the inspector still shows the fields, and every call fails with "Attempt to call a
## method on a placeholder instance" — silently, and only in the editor.

## What this component is. A slot only accepts its own kind. Declared on the BASE class (not on
## each subclass) so a slot can filter without knowing which subclasses exist.
enum Kind {ENGINE, BATTERY, TANK}

## Shown in the HUD and in the carry prompt.
@export var display_name: String = "Component"
@export var kind: Kind = Kind.ENGINE
## T1, T2, T4... A higher tier is meant to be BETTER, not merely more numerous.
@export var tier: int = 1
## The prop scene this part spawns as. A spec DESCRIBES a component; this is how a vehicle turns
## one into a real object it can fit. Kept here so a new tier is still just a .tres.
@export_file("*.tscn") var scene_path: String = ""
## Dry mass (kg). Added to the VEHICLE's own mass when fitted, never to its payload: a bolted-in
## part is part of the truck, not cargo the truck carries. See Vehicle.get_component_mass().
@export var mass_kg: float = 0.0

## Short label for the HUD, e.g. "T1 Electric Motor".
func label() -> String:
	return display_name
