class_name NetInterpolator
extends RefCounted

## DRY client-side smoothing for a server-authoritative replica. The server only sends updates at
## the network rate (~30 Hz), so applying them directly makes the node step/jitter. Instead, keep
## the latest replicated LOCAL transform and glide the node toward it every render frame.
##
## Used by any frozen client replica (vehicle, remote player, …): the owner feeds the target on
## each network update (set_target) and calls update() from its _process.

## Catch-up rate (1/s). Higher = snappier (less lag), lower = smoother (more lag).
var speed: float = 15.0

var _pos: Vector3 = Vector3.ZERO
var _basis: Basis = Basis.IDENTITY
var _has: bool = false

## Feed the latest target as a LOCAL transform (position relative to the parent + local basis).
## Snaps the node to it on the first call so it never interpolates from the world origin.
func set_target(node: Node3D, local_pos: Vector3, local_basis: Basis) -> void:
	_pos = local_pos
	_basis = local_basis
	if not _has:
		node.position = local_pos
		node.transform.basis = local_basis
		_has = true

## Glide the node toward the target. Call every frame (typically from _process).
func update(node: Node3D, delta: float) -> void:
	if not _has:
		return
	var f: float = clampf(speed * delta, 0.0, 1.0)
	node.position = node.position.lerp(_pos, f)
	node.transform.basis = node.transform.basis.slerp(_basis, f)

## Position-only variant: smooth the position toward the target but leave rotation untouched —
## for a locally-controlled entity whose look must stay immediate (the local player on foot:
## smooth the server-driven position while mouse-look stays responsive).
func set_position_target(node: Node3D, local_pos: Vector3) -> void:
	_pos = local_pos
	if not _has:
		node.position = local_pos
		_has = true

func update_position(node: Node3D, delta: float) -> void:
	if not _has:
		return
	node.position = node.position.lerp(_pos, clampf(speed * delta, 0.0, 1.0))

## Apply the latest target immediately (no smoothing). Use when smoothing would hurt — e.g. the
## object the local player is actively controlling (a driver wants responsiveness, not lag).
func snap_to(node: Node3D) -> void:
	if _has:
		node.position = _pos
		node.transform.basis = _basis

## Force the next set_target to snap instead of interpolate — e.g. after a reparent, where the
## local frame (and thus the local target) changed.
func snap_next() -> void:
	_has = false
