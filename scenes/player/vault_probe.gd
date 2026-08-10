class_name VaultProbe
extends RefCounted

## Geometric ledge probe, shared (DRY) by the server that ACTS on it (PlayerServer._try_start_vault) and
## the owner's debug HUD that just SHOWS it (CharacterAnimator._update_debug_label). Pure raycasts, no
## gameplay state: given a body, it answers "is a climbable ledge right ahead?" the same way on both.
##
## The "trace-based mantle" recipe: a steep face ahead (knee height), its walkable top surface (probed
## from above), and clearance to stand on it. The obstacle height picks the climb clip. Returns
## { "ok": bool, "key": String, "height": float, "landing": Vector3 } (landing is a WORLD point).
##
## NOTE the server's probe hits full collision; the client's sees PROPS but not the server-only terrain,
## so the HUD readout is exact against crates/containers and blank against terrain ledges (debug only).

const _CLEAR_MARGIN: float = 0.1  # start the stand-clearance ray just above the ledge
const _PROBE_HEADROOM: float = 0.5  # probe a bit above vault_max so a slightly-too-tall ledge still measures

## Probe from `body` (a Player). `stand_height` = the standing capsule height used for the clearance ray.
## The result ALWAYS carries the surface height found ahead (for the debug HUD) and a `reason` when it is
## not vaultable ("clear" / "slope" / "steep top" / "low" / "too tall" / "no room"). `ok` gates the server.
static func probe(body, stand_height: float = 1.8) -> Dictionary:
	var result: Dictionary = {"ok": false, "key": "", "height": 0.0, "landing": Vector3.ZERO, "reason": "clear"}
	var world: World3D = body.get_world_3d()
	if world == null:
		return result
	var space: PhysicsDirectSpaceState3D = world.direct_space_state
	if space == null:
		return result  # the space state is only valid during physics — never crash from an idle frame
	var up: Vector3 = body.global_transform.basis.y.normalized()  # body is gravity-oriented on both sides
	var fwd: Vector3 = -body.global_transform.basis.z
	fwd = fwd - up * fwd.dot(up)  # flatten the facing onto the ground plane
	if fwd.length() < 0.01:
		return result
	fwd = fwd.normalized()
	var feet: Vector3 = body.global_position
	var reach: Vector3 = fwd * body.vault_reach
	var rid: Array = [body.get_rid()]
	# Measure the surface height ahead FIRST (probe DOWN from above, just past the face), so the debug HUD
	# always shows what is in front — then the checks below only decide whether it's climbable.
	var top: Dictionary = _ray(space, feet + up * (body.vault_max_height + _PROBE_HEADROOM) + reach, feet + reach - up * 0.1, rid)
	if top.is_empty():
		return result  # nothing to stand on within reach -> "clear" (or a wall too tall to find a top)
	var height: float = (Vector3(top["position"]) - feet).dot(up)
	result["height"] = height  # reported even when not vaultable, for tuning
	# A steep face JUST BELOW the lip (near-horizontal normal) rules out a walkable slope. Checking near
	# the top (not a fixed knee height) means an ELEVATED ledge — a gap under it — is caught too; a slope's
	# face there reads as walkable and is rejected. Then the top's up normal + height band + clearance decide.
	var face_h: float = clampf(height - body.vault_face_margin, 0.1, height)
	var wall: Dictionary = _ray(space, feet + up * face_h, feet + up * face_h + reach, rid)
	if wall.is_empty() or absf(Vector3(wall["normal"]).dot(up)) > 0.5:
		result["reason"] = "slope"
		return result
	if Vector3(top["normal"]).dot(up) < 0.6:
		result["reason"] = "steep top"
		return result
	if height < body.vault_min_height:
		result["reason"] = "low"  # just a step — walk over it
		return result
	if height > body.vault_max_height:
		result["reason"] = "too tall"
		return result
	var ledge: Vector3 = feet + up * height + reach  # top point at the landing's forward offset
	if not _ray(space, ledge + up * _CLEAR_MARGIN, ledge + up * stand_height, rid).is_empty():
		result["reason"] = "no room"  # a low ceiling over the ledge
		return result
	var key: String = "vault"
	if height > body.vault_climb1_max:
		key = "climb_2m"
	elif height > body.vault_low_max:
		key = "climb_1m"
	result["ok"] = true
	result["key"] = key
	result["reason"] = ""
	# SafetyVault is a vault-OVER: clear the obstacle and land forward at ~ground height, so the pose
	# stays horizontal (no rise onto the top). The climbs end ON TOP of the ledge.
	if key == "vault":
		result["landing"] = feet + fwd * body.vault_over_distance
	else:
		result["landing"] = ledge + fwd * body.vault_land_forward + up * 0.02
	return result

## Solid-obstacle ray (MASK_OBSTACLE), ignoring the body. Returns the hit dict, {} when clear.
static func _ray(space: PhysicsDirectSpaceState3D, from_pos: Vector3, to_pos: Vector3, rid: Array) -> Dictionary:
	return space.intersect_ray(PhysicsRayQueryParameters3D.create(from_pos, to_pos, Globals.MASK_OBSTACLE, rid))
