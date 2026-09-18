class_name VehicleComponent
extends GenericProp

## A vehicle part as an OBJECT in the world: carried in your hands like a hauling crate, and bolted
## into a bay on a vehicle. What it DOES once fitted is not its business — it hands its spec over
## and VehicleDriveSpec works out the rest. That split is what lets a battery or a tank ship later
## without a line of engine code moving.
##
## Nearly everything comes from GenericProp and the PropSync child configured in the scene: carry,
## replication, pick-up and landing sounds. This adds one piece of state — WHICH bay it sits in.

## What this part is and what it can do. The prop is the body, the spec is its data sheet.
@export var spec: VehicleComponentSpec

## Name of the bay it is bolted into, "" while loose. Replicated AND persisted, and it has to be
## both: after a server restart the part comes back parented to the vehicle with the right pose,
## but nothing else would say which bay it belongs to. The shelf has to work that out geometrically
## on every reload; naming it here is a function we get to not write.
var slot_id: String = ""

func _ready() -> void:
	super._ready()
	# ONE source of truth for the weight. A mass typed into the scene as well would drift from the
	# spec, and the vehicle adds the SPEC's mass when the part goes in — so the same part would
	# weigh one thing lying on the ground and another bolted into a truck.
	if spec != null and spec.mass_kg > 0.0:
		mass = spec.mass_kg

## PropSync applies the replicated transform, then hands us the rest of the payload.
func apply_prop_data(data: Dictionary) -> void:
	if "slot_id" in data:
		slot_id = str(data["slot_id"])

## True while bolted into a vehicle.
func is_fitted() -> bool:
	return slot_id != ""

## What this part is called, for the HUD and the carry prompt.
func part_name() -> String:
	return spec.display_name if spec != null else "Component"
