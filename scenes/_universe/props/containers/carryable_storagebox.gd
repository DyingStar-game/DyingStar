class_name CarriableBox
extends GenericProp

## A carriable box for the dev spawn wheel — the 50 cm test box AND the pallet variants all use this
## one script (they were two byte-identical copies, box_50_cm.gd and this, before the merge). Extending
## GenericProp gives the standard networking, the carry contract (pick up with E) and the bed-ride
## behaviour; the SCENE provides the mesh, the physics CollisionShape3D and an interactable carry
## Area3D. Replicates as the "box" type (box_def.json), so only the scene/mesh differs.
##
## Kept SEPARATE from scenes/_universe/props/containers/* on purpose: those extend generic_storagebox.gd and
## are placed as STATIC, non-carriable decor in levels (sandbox_capital, the planets, SimpleBoxTest).
##
## The networked type key ("box") is set on the PropSync CHILD node per scene (see box_50cm.tscn), not here —
## so this script only needs GenericProp's behaviour and adds no _ready() of its own.
