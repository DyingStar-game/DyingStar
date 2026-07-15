class_name CarriableBox
extends GenericProp

## A carriable box for the dev spawn wheel — the 50 cm test box AND the pallet variants all use this
## one script (they were two byte-identical copies, box_50_cm.gd and this, before the merge). Extending
## GenericProp gives the standard networking, the carry contract (pick up with E) and the bed-ride
## behaviour; the SCENE provides the mesh, the physics CollisionShape3D and an interactable carry
## Area3D. Replicates as the "box" type (box_def.json), so only the scene/mesh differs.
##
## Kept SEPARATE from scenes/props/StorageBoxes/* on purpose: those extend generic_storagebox.gd and
## are placed as STATIC, non-carriable decor in levels (sandbox_capital, the planets, SimpleBoxTest).

func _ready() -> void:
	type_name = "box"
	super()
