class_name Box50cm
extends GenericProp

## A carriable 50 cm box. Everything — networking (uuid, replication, PropNet tick), the
## "carriable" group, carry/interact and collision-while-carried — lives in the PropSync child
## node (see the scene). A new carriable prop only needs `extends GenericProp` + a PropSync child
## with its `type_name` (here "box") and `enable_carry = true`.
