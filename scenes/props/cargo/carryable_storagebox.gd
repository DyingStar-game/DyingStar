extends GenericProp

## Carriable storage crate for the dev spawn wheel (the pallet variants). Extending GenericProp gives
## it the standard networking, the carry contract (pick up with E) and the bed-ride behaviour. The
## SCENE provides the mesh, the physics CollisionShape3D and an interactable "CarryArea" (the layer the
## look-at ray detects, like box_50cm / palette_container). Replicates as the "box" type (box_def.json),
## so only the scene/mesh differs — no per-crate definition file needed.
##
## Kept SEPARATE from scenes/props/StorageBoxes/* on purpose: those are placed as STATIC decor in
## levels (sandbox_capital, SimpleBoxTest), so they must stay frozen and non-carriable.

func _ready() -> void:
	type_name = "box"
	super()
