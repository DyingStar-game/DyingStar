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

## Longest the position is carried ahead of the last one received (s): a stream that stopped is not
## run after for more than this.
const LEAD_MAX_S: float = 0.15
## The lead runs this many times the last gap between targets: they come every 70 ms give or take 10,
## and a lead that stopped at exactly the last gap stopped the body ~50 ms whenever the next one came a
## little later than the one before (MovementProbe "stall" in bursts, playtest 2026-10-19). Past it the
## lead comes back as fast as it went: the server sends nothing for a body that stopped (a wall, a
## step), and a lead held there kept the view half a metre inside the wall for as long as the key was.
const LEAD_GAP_SHARE: float = 1.5
## Longest step (s) of the server's clock still read as the time between two positions of one stream; past
## it (or going back) the clock is another one -- a zone hand-over to another server -- and gives no speed.
const SERVER_GAP_MAX_S: float = 1.0

## How close to its target a glide is over (settle): under the 5 mm the wire snaps positions to.
const SETTLED_M: float = 0.0005
const SETTLED_RAD: float = 0.0005

var _pos: Vector3 = Vector3.ZERO
var _basis: Basis = Basis.IDENTITY
var _has: bool = false
# The lead of update_position: how fast the targets have been moving, when the last one came, and how
# long the one before it took.
var _vel: Vector3 = Vector3.ZERO
var _target_us: int = -1
var _gap_s: float = 0.0
var _server_ms: float = -1.0  # the server's simulation time of the last target, -1 when it sent none

## Feed the latest target as a LOCAL transform (position relative to the parent + local basis).
## Snaps the node to it on the first call so it never interpolates from the world origin.
func set_target(node: Node3D, local_pos: Vector3, local_basis: Basis) -> void:
	_pos = local_pos
	_basis = local_basis
	if not _has:
		node.position = local_pos
		node.transform.basis = local_basis
		_has = true

## True once a target came in: before that, lead_target has nothing to say.
func has_target() -> bool:
	return _has

## Glide the node toward the target. Call every frame (typically from _process).
func update(node: Node3D, delta: float) -> void:
	if not _has:
		return
	var f: float = clampf(speed * delta, 0.0, 1.0)
	node.position = node.position.lerp(_pos, f)
	node.transform.basis = node.transform.basis.slerp(_basis, f)

## True once [param node] is on its target (within SETTLED_M and SETTLED_RAD), where it is put exactly:
## the glide is over until the next set_target, and its owner may stop calling update(). True without
## a target.
func settle(node: Node3D) -> bool:
	if not _has:
		return true
	if node.position.distance_to(_pos) > SETTLED_M \
			or node.transform.basis.get_rotation_quaternion().angle_to(_basis.get_rotation_quaternion()) > SETTLED_RAD:
		return false
	snap_to(node)
	return true


## Position-only variant: smooth the position toward the target but leave rotation untouched —
## for a locally-controlled entity whose look must stay immediate (the local player on foot:
## smooth the server-driven position while mouse-look stays responsive).
##
## [param usec] is when it came (Time.get_ticks_usec, the default): with the one before, it gives the
## speed update_position leads by. [param server_ms] is the server's simulation time of that position
## (servergodot_ms, -1 when it sent none): when the last two have it, the speed is measured against it
## instead -- positions that waited in the socket come in the same frame, and their arrival times made
## up speeds four times the real one (MovementProbe same_frame, playtest 2026-10-22).
func set_position_target(node: Node3D, local_pos: Vector3, usec: int = -1, server_ms: float = -1.0) -> void:
	var now: int = Time.get_ticks_usec() if usec < 0 else usec
	if _has and _target_us >= 0:
		if server_ms >= 0.0 and _server_ms >= 0.0:
			var server_gap_s: float = (server_ms - _server_ms) / 1000.0
			if server_gap_s > 0.0 and server_gap_s <= SERVER_GAP_MAX_S:
				_gap_s = server_gap_s
				_vel = (local_pos - _pos) / _gap_s
			elif server_gap_s != 0.0:
				_vel = Vector3.ZERO  # another server's clock: no speed across it
		elif now - _target_us > 5000:
			_gap_s = float(now - _target_us) / 1e6
			_vel = (local_pos - _pos) / _gap_s
	_pos = local_pos
	_target_us = now
	_server_ms = server_ms
	if not _has:
		node.position = local_pos
		_has = true

## [param lead]: carry the target on at the speed of the last two, for at most LEAD_GAP_SHARE times
## the time between them (and LEAD_MAX_S) -- for the owner while its move keys are held. Gliding after positions that come
## every 70 ms, the body caught each one in 40 and waited for the next: it moved in steps, 14 times a
## second (MovementProbe "stall", playtest 2026-10-19). Led, it keeps going between them. Never past a
## stop: keys released, no lead, and the body settles on what the server said.
func update_position(node: Node3D, delta: float, lead: bool = false, usec: int = -1) -> void:
	if not _has:
		return
	node.position = node.position.lerp(lead_target(lead, usec), clampf(speed * delta, 0.0, 1.0))


## Where update_position glides to now: the last target, carried on when [param lead] (see there).
func lead_target(lead: bool, usec: int = -1) -> Vector3:
	if not lead or _target_us < 0:
		return _pos
	var now: int = Time.get_ticks_usec() if usec < 0 else usec
	var age: float = float(now - _target_us) / 1e6
	return _pos + _vel * lead_time(age, minf(_gap_s * LEAD_GAP_SHARE, LEAD_MAX_S))


## How far ahead (s) the lead runs [param age] s after the last target: on with it up to [param cap],
## then back down to nothing over as long again. Static and pure.
static func lead_time(age: float, cap: float) -> float:
	if age <= cap:
		return maxf(age, 0.0)
	return maxf(2.0 * cap - age, 0.0)

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
	_target_us = -1  # the next target is in another frame: no speed from this one to it
	_server_ms = -1.0
	_vel = Vector3.ZERO
