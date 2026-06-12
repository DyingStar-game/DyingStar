class_name Box50cm
extends GenericProp

## A carriable 50 cm box. Everything — networking (uuid, replication, PropNet tick), the
## "carriable" group, carry/interact and collision-while-carried — is inherited from
## GenericProp. A new carriable prop only needs `extends GenericProp` + its type name.

func _ready() -> void:
	type_name = "box"
	super()
