class_name PlayerServer
extends Node

## Server-authoritative logic for a player — runs ONLY on the dedicated game server. Owns (over the
## migration) the physics tick, input application, carry / line-of-sight, doors, spawns and the
## server_action_received dispatcher. Created by Player as a child node; it reaches the shared body,
## nodes and state through `player`. Helpers still on the Player facade are called via `player.` until
## they migrate too. (Filled in incrementally.)

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")
## How long a body waits for the ground under it before being released anyway. Generous: a cold start
## regenerates every chunk on worker threads, and being released early is exactly the bug.
const SPAWN_GROUND_TIMEOUT: float = 20.0
## Kept in sync with Player.JUMP — a `match` pattern needs a compile-time constant, so we can't read
## `player.JUMP` here.
const JUMP: String = "jump"
## Yaw applied to a carried object per mouse-wheel notch (radians) — see the "carry_rotate" action.
const CARRY_ROTATE_STEP := deg_to_rad(15.0)
## Free-rotate gain: radians of object rotation per unit of streamed mouse motion. The client streams
## the same scaled motion it uses for the camera (event.relative * 0.001), so this is tuned so a
## screen-width drag is roughly a full turn — see the "carry_free_rotate" action.
const CARRY_FREE_ROTATE_GAIN := 6.0
## Dev spawn wheel: how far above / below the aimed point we look for the ground (m). Generous enough
## for a slope or a step in front of us, short enough that a miss means "there really is nothing here".
const GROUND_SEARCH := 30.0
## Seconds a dialog line stays up before the queue releases the next one (see _server_update_dialog).
const _DIALOG_LINE_INTERVAL := 4.0
## Max distance (m) between the player and a shelf for a drop to snap into it (see _shelf_for_drop).
const _SHELF_DROP_RANGE := 4.0

## The body / facade this role drives (a Player). Untyped ON PURPOSE: typing it `Player` would create a
## cyclic class_name dependency (Player references PlayerServer/PlayerClient, which reference Player) and
## break global script compilation. Untyped duck-typing still reaches every Player member.
var player

## Server-only: consecutive quasi-still ticks, used to throttle move_and_slide for idle players.
var _idle_settled_ticks: int = 0

## Jumps performed by this player, replicated with the jump event so each one is a NEW value (see the
## jump in _physics_process): an identical repeated value would be swallowed by delta compression.
var _jump_count: int = 0
## Dev spawn wheel: catalogue keys asked for since the last physics tick (see _spawn_from_catalog).
var _spawn_queue: Array[String] = []
## Server-only line-of-sight ray (lazy) + carry-prompt throttle timer.
var _los_ray: RayCast3D = null
var _carry_prompt_timer: float = 0.0
## Orientation of the carried crate ON ITS MOUNT, in BODY-local space: the wheel notch and the
## middle-mouse free rotate accumulate into it, _server_update_carried_item re-applies it every tick,
## and it survives the drop as the crate's spin about the placement surface normal. Reset per pickup.
var _carry_basis: Basis = Basis.IDENTITY
## Last resolved placement under the crosshair (see CarryPlacement.resolve). Refreshed every tick
## while carrying; feeds the E prompt. The drop re-resolves rather than trusting this.
var _place: Dictionary = {}
## Gait, set by the owner's replicated intent (see server_action_received): sprint held, and the
## mouse-wheel-chosen walk speed (0 until first set -> fall back to the default walk_speed).
var _sprint_held: bool = false
var _stance: int = 0  # 0 = standing, 1 = crouched, 2 = prone (server-authoritative, replicated as "stance")
var _stance_request: int = 0  # last stance the owner asked for; validated + applied in the physics step
var _collider: CollisionShape3D = null  # physics capsule (OWN copy — resized per stance, see setup)
var _stand_collider_height: float = 1.8  # standing capsule height, captured from the scene at setup
var _walk_speed_target: float = 0.0  # mouse-wheel walk speed; seeded from player.walk_speed in setup()
## Landing: the server emits a "land:<n>" event (via the whitelisted `action` field, like the jump) the
## instant is_on_floor() becomes true again, so clients end the jump loop crisply. No extra replication.
var _land_count: int = 0
var _was_airborne: bool = false
## Emotes: replicated like the jump ("emote:<key>:<n>" on the whitelisted action field) so every client
## plays the emote on this body. The counter defeats delta compression (same emote twice in a row).
var _emote_count: int = 0
## Seat state: replicated the same way ("seat:<role>:<n>" / "unseat:<n>") so every remote avatar shows the
## sit/drive pose (a seated remote is not reparented, so this is its only seat signal).
var _seat_count: int = 0
## Auto-vault (climb-onto): a scripted forward+up slide over a low obstacle / ledge, replicated like the
## jump ("vault:<key>:<n>" on the whitelisted action field) so every body plays the matching climb clip.
## While _vaulting the physics step just drives the slide (gravity/input/move suspended).
var _vault_count: int = 0
## True once this body has actually been inside a gravity well. Gates the release to the world
## frame: before it, an empty gravity stack only means the AreaDetector has not reported yet.
var _had_gravity: bool = false
## True once the terrain under this body has been seen at least once. See _hold_until_ground.
var _ground_seen: bool = false
var _ground_wait: float = 0.0
var _vaulting: bool = false
var _vault_time: float = 0.0
var _vault_duration: float = 0.6
var _vault_start: Vector3 = Vector3.ZERO  # parent-frame (local) start, same space as player.position
var _vault_end: Vector3 = Vector3.ZERO    # parent-frame (local) landing on the ledge
var _vault_arc: float = 0.0               # vault-OVER arc peak (m) above the straight path; 0 = climbs (no arc)
var _vault_up_local: Vector3 = Vector3.ZERO  # parent-frame up direction, along which the arc is added
var _vault_cooldown: float = 0.0          # seconds before another vault may start
## Step-up: a short, SILENT scripted glide onto a low obstacle (no vault clip, keeps momentum) — smooth,
## speed-independent, and no cooldown so stairs climb freely. Same parent-frame (local) convention.
var _stepping: bool = false
var _step_start: Vector3 = Vector3.ZERO
var _step_end: Vector3 = Vector3.ZERO
var _step_time: float = 0.0

# Dialog — a "dialog" action does NOT go on the wire straight away: the AI can push a whole
# conversation in one burst, and replicating it as fast as it arrives would leave only the last line
# on screen. Lines queue here instead and _server_update_dialog releases the OLDEST one every
# _DIALOG_LINE_INTERVAL seconds, so they read one after the other.
## Lines still waiting to be said, oldest first (FIFO).
var _dialog_queue: Array[String] = []
## Seconds left before the current line is replaced by the next one (or cleared).
var _dialog_timer: float = 0.0
## True while a line is on the clients' screens, i.e. while we still owe them a clearing null. This is
## what stops the empty queue from re-sending that null every 2 s forever.
var _dialog_active: bool = false

# NPC — the `is_npc` flag and `npc_go_to_position` target live on the Player facade (set by server.gd
# / external AI); everything below is server-only working state owned by this role.
var _npc_path_retry_timer: float = 0.0
## Server-only: consecutive idle ticks (no goal, no facing turn, settled on the floor), used to
## throttle move_and_slide for idle NPCs — the same sleep real players get (see _physics_process).
var _npc_idle_ticks: int = 0
## Throttle for the temporary _NPC_DEBUG report.
var _npc_debug_timer: float = 0.0
## Progress watchdog (see _npc_update_stuck): where the NPC stood when the current window opened, and
## how long that window has been running.
var _npc_progress_ref: Vector3 = Vector3.ZERO
var _npc_progress_timer: float = 0.0
## How many rungs of the recovery ladder we have climbed without regaining headway. Reset by real
## progress and by a new goal; drives _npc_try_unstick's escalation.
var _npc_recover_step: int = 0
## Intermediate world point the ROUTE is aimed at instead of the goal while working around a blockage
## (null = none), and how long it stays valid. A detour is never a destination: arrival is always judged
## against the real goal.
var _npc_detour = null
var _npc_detour_timer: float = 0.0
## Detours taken since this goal was handed to us. Unlike _npc_recover_step it is NOT cleared by
## headway — walking to a detour IS headway, so the step counter resets every cycle and can never
## measure a goal we keep failing to reach. This one only clears on a new goal.
var _npc_detour_count: int = 0
## Last goal we saw, so a NEW one can reset the watchdog and drop a stale detour.
var _npc_goal_seen = null
## Runtime-baked navigation coverage for this NPC, driven straight through the NavigationServer rather
## than a NavigationRegion3D node — a node would inherit its parent's transform and drag the mesh out to
## the planet's coordinates, which is exactly what must not happen (see _npc_to_nav). RID() until the
## NPC first receives a destination.
var _npc_nav_region: RID = RID()
## The last successfully baked mesh (kept for diagnostics; the server holds its own copy).
var _npc_nav_mesh: NavigationMesh = null
## Current path, in NAV SPACE, and how far along it we are. Replaces NavigationAgent3D, which cannot be
## used here: it starts every query from its parent's global_position — the very 1e10 coordinate that
## breaks the navigation server's polygon connectivity.
var _npc_path: PackedVector3Array = PackedVector3Array()
var _npc_path_idx: int = 0
## Surface-aligned frame the region is baked in and parented to (see _npc_surface_frame). Re-anchored on
## the NPC at each bake so Recast's hard-coded +Y-is-up holds on a curved planet.
var _npc_nav_frame: Node3D = null
## Private navigation map holding ONLY this NPC's runtime bake (see _ensure_npc_nav_region).
var _npc_nav_map: RID = RID()
## World-space center of the last bake; we re-bake once the NPC wanders past _NPC_NAV_REBAKE_DIST of it.
var _npc_nav_bake_center = null
## World-space goal the last bake was sized to hold; a goal that moves away from it forces a re-bake.
var _npc_nav_bake_goal = null
## True while an async bake is in flight, so we don't queue a second one on top.
var _npc_nav_baking: bool = false

## Half-extent (m) of the cube baked around the NPC. Kept small so baking planet-scale terrain stays
## cheap; the NPC re-bakes as it travels.
const _NPC_NAV_HALF_EXTENT: float = 30.0
## Distance (m) from the last bake center past which we bake a fresh region ahead of the NPC.
const _NPC_NAV_REBAKE_DIST: float = 18.0
## Furthest the bake box reaches toward the goal. A goal beyond this is aimed at through the box edge:
## the NPC walks there, the next bake carries it further. Bounds the voxelized volume.
const _NPC_NAV_MAX_EXTENT: float = 60.0
## Slack (m) around the NPC↔goal box, so neither endpoint lands on an eroded border of the mesh.
const _NPC_NAV_GOAL_MARGIN: float = 4.0
## Vertical half-height (m) of the bake box around the NPC/goal. Both stand on the ground, so a taller
## box only voxelizes empty sky (and the box is per-NPC, per-rebake — it has to stay cheap).
const _NPC_NAV_VERTICAL: float = 8.0
## How close (m, measured in the ground plane) the NPC must get to a path waypoint before we move on to
## the next one. Must stay WELL under the clearance the mesh guarantees around geometry: the funnelled
## path hugs an obstacle corner at exactly agent_radius (0.30 m) and the capsule eats 0.265 m of that,
## so a waypoint dropped from 0.5 m away — the old value — aims the NPC at the point PAST the corner
## while it is still short of the corner, and that shortcut chord goes through the wall. This is only
## the fallback anyway: _npc_next_path_point normally advances on the passed-the-waypoint test.
const _NPC_WAYPOINT_REACHED: float = 0.15
## Beyond this ground-plane distance (m) a waypoint is never considered "passed". The passed test uses a
## plane, which extends sideways forever: a body shoved off-route (a player walking into it) must not
## silently skip the corner it still has to walk around.
const _NPC_PASSED_MAX_DIST: float = 1.5
## How far (m) an interior path corner is pushed off the geometry it hugs, see _npc_widen_path_corners.
## Enough to cover the turn overshoot at _NPC_WALK_SPEED / _NPC_TURN_SHARPNESS; it is only ever applied
## where the mesh has the room, so it cannot close a doorway.
const _NPC_CORNER_CLEARANCE: float = 0.35
## How far off the mesh (m) a pushed corner may land before the push is shrunk. One cell plus a little,
## for the closest-point query's own quantisation.
const _NPC_CORNER_ON_MESH_EPS: float = 0.12
## Ground-plane distance to the GOAL under which the NPC counts as arrived (and we notify the brain).
## Deliberately looser than _NPC_WAYPOINT_REACHED: the goal can sit slightly off the navmesh, so the last
## reachable waypoint may stop us a bit short — this must forgive that gap, or arrival never fires.
const _NPC_ARRIVED_DIST: float = 1.5
## NPC ground speed (m/s). Deliberately its OWN value, not player.walk_speed — a player's walk_speed is
## tuned for the owner (5 m/s in the scene) and made NPCs sprint; NPCs walk at this steady pace instead.
const _NPC_WALK_SPEED: float = 2.0
## How sharply the body turns toward the walk direction (exponential smoothing rate, 1/s). ~8 settles a
## 90° turn in about half a second; higher snaps, lower feels like a boat.
const _NPC_TURN_SHARPNESS: float = 8.0
## How long (s) an NPC may make no headway before the recovery ladder escalates one rung. At
## _NPC_WALK_SPEED it covers 5 m in this window, so falling under _NPC_PROGRESS_MIN means it is scraping
## geometry, orbiting a waypoint, or parked against a wall — never just walking slowly.
const _NPC_PROGRESS_WINDOW: float = 2.5
## Ground distance (m) that counts as headway over _NPC_PROGRESS_WINDOW. 1 m in 2.5 s is 20% of walking
## pace: generous enough that squeezing through a doorway is not mistaken for a wedge.
const _NPC_PROGRESS_MIN: float = 1.0
## Radius (m) of the ring the detour rung samples for an intermediate point to route through. Far enough
## to leave the dead end that trapped us, near enough to still be inside the baked coverage.
const _NPC_DETOUR_RADIUS: float = 6.0
## How many directions around the NPC the detour rung samples.
const _NPC_DETOUR_SAMPLES: int = 12
## How long (s) a chosen detour stays the routing target before the NPC goes back to aiming at the real
## goal. A cap, not a schedule: reaching the detour retires it early.
const _NPC_DETOUR_TIMEOUT: float = 10.0
## Furthest the stuck recovery may teleport an NPC onto the navmesh. Kept ~a body width: the snap skips
## collision, so anything beyond "the mesh I'm already standing on" tunnels it through walls.
const _NPC_STUCK_SNAP_MAX: float = 1.5
## Group the bake TRAVERSES for source geometry. The NPC's own parent is added to it automatically (see
## _ensure_npc_nav_region) — this is not a scene-authoring hook, it exists because GROUPS_WITH_CHILDREN
## is the only source mode that lets us walk the world while emitting geometry in a different frame.
const _NPC_NAV_SOURCE_GROUP: StringName = &"npc_nav_source"
## Physics layers the bake voxelizes: world | vehicle | prop — everything solid EXCEPT the player layer,
## which must stay out or the NPC (and every other player standing nearby) would bake its own capsule in
## as an obstacle. Same set the line-of-sight rays treat as solid.
const _NPC_NAV_COLLISION_MASK: int = Globals.MASK_OBSTACLE
## Physics frame of the last synchronous world-geometry parse ANY NPC ran (class-wide, see
## _ensure_npc_nav_region): parse_source_geometry_data walks every collider under the planet ON THE MAIN
## THREAD, so several NPCs re-baking in the same frame stack those parses into one giant spike. The
## guard lets one NPC parse per physics frame; the others simply retry next tick.
static var _npc_nav_parse_frame: int = -1

## One-time spawn init, called by Player._ready() once `player` is wired and both are in the tree.
## Server placement: sit the body at its spawn position and start monitoring detection zones.
## (This is the former dedicated-server branch of Player._ready.)
func setup() -> void:
	player.position = player.spawn_position
	player.connect_area_detect()
	player.update_last_basis()
	# Start at the scene's walk speed, so the wheel tier is a real speed from the very first frame
	# (it used to start at 0 as a "never set" marker, which the HUD then displayed as 0.0 m/s).
	_walk_speed_target = player.walk_speed
	# Give the physics collider its OWN capsule so shrinking it for crouch/prone doesn't also shrink the
	# AreaDetector (gravity / seat / zone detection), which shares the scene's capsule resource.
	_collider = player.get_node_or_null("Placeholder_Collider") as CollisionShape3D
	if _collider != null and _collider.shape is CapsuleShape3D:
		_collider.shape = _collider.shape.duplicate()
		_stand_collider_height = (_collider.shape as CapsuleShape3D).height

## Physics-capsule height (m) for a stance: standing (from the scene), crouched, or prone.
func _stance_height(stance: int) -> float:
	if stance == 1:
		return player.crouch_collider_height
	if stance == 2:
		return player.prone_collider_height
	return _stand_collider_height

## Shrink/restore the physics capsule for the stance, keeping its bottom (feet) on the ground.
func _apply_stance_collider(stance: int) -> void:
	if _collider == null or not (_collider.shape is CapsuleShape3D):
		return
	var h: float = _stance_height(stance)
	(_collider.shape as CapsuleShape3D).height = h
	_collider.position.y = h * 0.5  # capsule is centered on its node: bottom stays at the body origin

## Standing up (to a TALLER stance) needs clearance: a ray from the current head up to the taller head
## must hit nothing solid overhead, else we stay low (can't stand under a ceiling).
func _has_headroom(target_stance: int) -> bool:
	if _collider == null or not (_collider.shape is CapsuleShape3D):
		return true
	var current_h: float = (_collider.shape as CapsuleShape3D).height
	var target_h: float = _stance_height(target_stance)
	if target_h <= current_h:
		return true
	var up: Vector3 = player.up_direction
	return _solid_ray(player.global_position + up * current_h, player.global_position + up * (target_h + 0.05)).is_empty()

## Cast for a solid obstacle (MASK_OBSTACLE) between two world points, ignoring our own body. Returns the
## hit dict, or {} when clear. Shared by the headroom check and the vault probes (DRY).
func _solid_ray(from_pos: Vector3, to_pos: Vector3) -> Dictionary:
	var space = player.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from_pos, to_pos, Globals.MASK_OBSTACLE, [player.get_rid()])
	return space.intersect_ray(query)

## Physics step: apply a pending stance change now that the space state is valid. Standing up to a taller
## stance needs headroom (else we drop the request and stay low). Replicates only on an actual change.
func _process_stance_request() -> void:
	if _stance_request == _stance:
		return
	if _stance_height(_stance_request) > _stance_height(_stance) and not _has_headroom(_stance_request):
		_stance_request = _stance  # blocked overhead: drop the stand-up
		return
	_stance = _stance_request
	_apply_stance_collider(_stance)
	player.stance = _stance
	if _stance != 0 and player.hands_item != null:  # crouch/prone can't hold a carried box -> drop it
		_server_drop_carried_item()
	player.server_send_properties_to_client({"stance": _stance})

## Authoritative dispatcher for a client action, called by the network layer through Player (only the
## dedicated server ever receives it). Every branch reads/writes the shared body via `player`.
func server_action_received(data: Dictionary) -> void:
	match data["action"]:
		JUMP:
			player.is_jumping = true
			if player.hands_item != null:
				_server_drop_carried_item()  # jumping drops what you carry
		"sprint":
			_sprint_held = bool(data.get("held", false))  # Shift held: run at sprint_speed
		"stance":
			# Movement stance toggle (0 standing / 1 crouched / 2 prone). Server-authoritative: we set it,
			# cap the speed + resize the collider from it, and replicate so remotes show the pose. We run in
			# _process (the headroom ray needs the physics space state, null here) -> just record the
			# request; the physics step validates + applies it (see _process_stance_request).
			_stance_request = clampi(int(data.get("value", 0)), 0, 2)
		"walk_speed":
			# Mouse-wheel-chosen walk speed (owner intent), clamped to the allowed range.
			_walk_speed_target = clampf(float(data.get("value", player.walk_speed)),
				player.walk_speed_min, player.walk_speed_max)
		"emote":
			# Play an emote on this body for everyone. Validate the key, then replicate it as an event.
			var emote_key: String = str(data.get("key", ""))
			if not EmoteCatalog.get_emote(emote_key).is_empty():
				_emote_count += 1
				player.server_send_properties_to_client({"action": "emote:%s:%d" % [emote_key, _emote_count]})
		"toggle_flashlight":
			# Server-authoritative: flip the state and replicate it so the owner AND other players
			# see the torch (replicated as a state, not the action — a missed event can't desync it).
			player.flashlight.visible = not player.flashlight.visible
			player.server_send_properties_to_client({"flashlight": player.flashlight.visible})
		"toggle_eva":
			# EVA free-flight (dev test aid): flip the authoritative state; _physics_process then flies
			# the body where the camera looks with no gravity. Zero the velocity so leaving EVA doesn't
			# fling the player. State-replicated (not the event) so a dropped toggle can't desync it.
			#
			# Checked HERE as well as on the client, and this is the check that counts: movement is
			# server-authoritative, so a client that asked anyway — an old build, a modified one —
			# would still fly. Switching a tool off has to happen where the tool actually runs.
			if not Globals.is_dev_tool_disabled("toggle_eva"):
				player.eva_mode = not player.eva_mode
				player.velocity = Vector3.ZERO
				player.server_send_properties_to_client({"eva": player.eva_mode})
		"screen_state":
			# A 3D screen (mining depot) button was pressed: route it to that screen.
			if player.screen_interacting and player.screen_interacting.has_method("update_screen"):
				player.screen_interacting.update_screen(data)
		"update_property":
			# Generic player-property update (tech-debt A): apply the authoritative side-effects we
			# know about, then replicate every property to nearby clients.
			var props: Dictionary = data.duplicate()
			props.erase("action")
			if props.has("tools"):
				player.mining_tool.server_set_tool(str(props["tools"]))
			if props.has("head"):
				# Apply on the server too so the interaction ray + carried item follow the gaze
				# (planet only; in 0g the body orientation is used instead).
				player.camera_pivot.rotation.x = float(props["head"])
			if props.has("head_yaw"):
				player.camera_pivot.rotation.y = float(props["head_yaw"])  # seated free-look yaw
			player.server_send_properties_to_client(props)
		"perforate_rock":
			# Authoritative fracture: cut the targeted rock along the aimed fault.
			var rock = _find_mining_rock(str(data.get("uuid", "")))
			if rock and rock.has_method("server_perforate"):
				var h: Dictionary = data.get("hit", {})
				var dd: Dictionary = data.get("dir", {})
				rock.server_perforate(
					Vector3(h.get("x", 0.0), h.get("y", 0.0), h.get("z", 0.0)),
					Vector3(dd.get("x", 0.0), dd.get("y", 0.0), dd.get("z", 0.0)))
		"delete_prop":
			# Admin cleanup tool: permanently remove a player-spawned prop.
			var del_type: String = str(data.get("type", ""))
			var del_uuid: String = str(data.get("uuid", ""))
			if del_uuid == "" or not (del_type in ["miningrock", "box", "mining_depot", "crate_container", "vehicle"]):
				print("🗑️ Admin delete refused: type=%s uuid=%s" % [del_type, del_uuid])
			elif NetworkOrchestrator.protected_prop_uuids.has(del_uuid):
				# World infrastructure placed by designers (e.g. a depot in the city): keep it.
				print("🗑️ Admin delete refused: %s is protected world infrastructure" % del_uuid)
			else:
				# Free the node (removes its collision body) AND tell Horizon to drop it from the GORC +
				# database. Both are needed: queue_free alone may not replicate the delete, and the GORC
				# delete alone leaves a collision ghost.
				var prop = _find_deletable_prop(del_uuid)
				if prop != null and is_instance_valid(prop):
					print("🗑️ Admin delete: freeing local node %s %s" % [del_type, del_uuid])
					_reparent_children_of_prop(prop)
					prop.queue_free()
				if NetworkOrchestrator.network_agent.has_method("_on_prop_delete"):
					# Not held locally (e.g. loaded from the database): tell Horizon directly.
					print("🗑️ Admin delete: forwarding to Horizon %s %s" % [del_type, del_uuid])
					NetworkOrchestrator.network_agent._on_prop_delete(del_uuid, del_type)
		"spawn_prop":
			# Dev spawn wheel (key T): the client only NAMES what it wants; we own everything else.
			_spawn_from_catalog(str(data.get("key", "")))
		"enter_vehicle":
			var veh = _find_vehicle(str(data.get("target_uuid", "")))
			if veh != null and veh.has_method("server_enter"):
				veh.server_enter(player, str(data.get("seat", "")))
				if is_instance_valid(player._seat_node):  # enter succeeded (seat free, door open)
					_seat_count += 1
					var role := "driver" if player._seat_node.is_driver_seat() else "passenger"
					player.server_send_properties_to_client({"action": "seat:%s:%d" % [role, _seat_count]})
				else:  # refused (seat occupied / door blocked) -> undo the client optimistic entry
					_seat_count += 1
					player.server_send_properties_to_client({"action": "unseat:%d" % _seat_count})
		"exit_vehicle":
			var veh_out = _find_vehicle(str(data.get("target_uuid", "")))
			if veh_out != null and veh_out.has_method("server_exit"):
				var was_seated := is_instance_valid(player._seat_node)
				veh_out.server_exit(player)
				if was_seated:
					_seat_count += 1
					player.server_send_properties_to_client({"action": "unseat:%d" % _seat_count})
		"vehicle_input":
			var veh_in = _find_vehicle(str(data.get("target_uuid", "")))
			if veh_in != null and veh_in._pilot == player and veh_in.has_method("set_drive_input"):
				veh_in.set_drive_input(
					float(data.get("throttle", 0.0)),
					float(data.get("steer", 0.0)),
					bool(data.get("brake", false)))
		"reset_vehicle":
			var veh_r = _find_vehicle(str(data.get("target_uuid", "")))
			if veh_r != null and veh_r._pilot == player and veh_r.has_method("reset_upright"):
				veh_r.reset_upright()
		"vehicle_handbrake":
			var veh_h = _find_vehicle(str(data.get("target_uuid", "")))
			if veh_h != null and veh_h._pilot == player and veh_h.has_method("toggle_handbrake"):
				veh_h.toggle_handbrake()
		"carry_rotate":
			# Spin the carried object around the vertical by one notch. The crate is pinned to its mount
			# each tick, so the rotation goes into _carry_basis (body-local) rather than the body's own
			# transform. Vector3.UP in that frame IS the player's up_direction (the body is aligned to
			# gravity), so the crate stays upright on a planet.
			var step: float = CARRY_ROTATE_STEP * signf(float(data.get("dir", 1)))
			_rotate_held(Basis(Vector3.UP, step))
		"carry_free_rotate":
			# Hold the middle mouse button and move the mouse to tumble the carried object on all axes, in
			# addition to the wheel's single-axis notch. Yaw about the body's up from mouse X; pitch about
			# its right axis from mouse Y (the camera pivot only pitches, so its right IS the body's), so
			# a drag maps to what the player sees.
			var dxr: float = float(data.get("dx", 0.0)) * CARRY_FREE_ROTATE_GAIN
			var dyr: float = float(data.get("dy", 0.0)) * CARRY_FREE_ROTATE_GAIN
			_rotate_held(Basis(Vector3.UP, dxr) * Basis(Vector3.RIGHT, dyr))
		"vehicle_ignition":
			var veh_i = _find_vehicle(str(data.get("target_uuid", "")))
			if veh_i != null and veh_i._pilot == player and veh_i.has_method("toggle_engine"):
				veh_i.toggle_engine()  # refused by the vehicle itself if it is still rolling
		"vehicle_horn":
			var veh_n = _find_vehicle(str(data.get("target_uuid", "")))
			if veh_n != null and veh_n._pilot == player and veh_n.has_method("set_horn"):
				veh_n.set_horn(bool(data.get("pressed", false)), bool(data.get("special", false)))
		"vehicle_lights":
			var veh_l = _find_vehicle(str(data.get("target_uuid", "")))
			if veh_l != null and veh_l._pilot == player and veh_l.has_method("toggle_headlights"):
				veh_l.toggle_headlights()
		"vehicle_door":
			# A door handle is operated on foot by anyone nearby - NOT gated on the driver. Server-
			# authoritative: (1) the box it aimed at must match the player's side (outdoor on foot, indoor
			# when seated in this vehicle), and (2) that box must have a clear sightline (see _can_see).
			var veh_d = _find_vehicle(str(data.get("target_uuid", "")))
			if veh_d != null and veh_d.has_method("server_toggle_door"):
				var handle_d: Node3D = veh_d.get_door_handle(str(data.get("door_id", ""))) \
						if veh_d.has_method("get_door_handle") else null
				var inside_d: bool = veh_d.has_method("is_occupied_by") and veh_d.is_occupied_by(player)
				var claimed_side: String = str(data.get("side", ""))
				var side_ok: bool = claimed_side == "" or claimed_side == ("indoor" if inside_d else "outdoor")
				if side_ok and (handle_d == null or _can_see(handle_d)):
					veh_d.server_toggle_door(str(data.get("door_id", "")))
					if not inside_d:  # operated ON FOOT -> play the reach-out gesture for everyone
						_emote_count += 1
						player.server_send_properties_to_client({"action": "emote:interact:%d" % _emote_count})
		"npc_go_to_position":
			# Server-authoritative: set the NPC's target position (the AI sets it on the Player facade,
			# then this role drives the body toward it). The AI can change it at any time, and the NPC
			# will re-path to it.
			player.is_npc = true
			if player.is_npc:
				# Walking owns the body orientation (_npc_face): drop any pending facing goal.
				player.npc_face_position = null
				var pos: Dictionary = data.get("position", {})
				var ref_uuid = data.get("uuid", null)
				var npc_position = Vector3(pos.get("x", 0.0), pos.get("y", 0.0), pos.get("z", 0.0))
				if ref_uuid == null or str(ref_uuid) == "":
					# No reference given: the position already is in the NPC's own referential.
					player.npc_go_to_position = npc_position
				else:
					# The position is local to the referenced object (a building, a vehicle, ...):
					# rebase it onto the NPC parent's referential so the target and the body share a frame.
					var ref_node := _find_node_by_uuid(get_tree().get_root(), str(ref_uuid))
					if ref_node is Node3D:
						var world_pos: Vector3 = (ref_node as Node3D).global_transform * npc_position
						var npc_parent = player.get_parent()
						player.npc_go_to_position = (npc_parent as Node3D).global_transform.affine_inverse() * world_pos \
								if npc_parent is Node3D else world_pos
					else:
						push_warning("npc_go_to_position: no Node3D found for uuid %s" % str(ref_uuid))
		"npc_face_position":
			# Server-authoritative: pivot the STANDING NPC toward a point. Same payload contract
			# as npc_go_to_position ({uuid, position}: position local to the referenced object).
			# The turn itself runs in _npc_update_face_target — around the body's own up axis, so
			# it stays upright in any gravity frame; the brain sending absolute Euler rotations
			# is exactly what used to lay the body down.
			if player.is_npc:
				var fpos: Dictionary = data.get("position", {})
				var fref = data.get("uuid", null)
				var face_position = Vector3(fpos.get("x", 0.0), fpos.get("y", 0.0), fpos.get("z", 0.0))
				if fref == null or str(fref) == "":
					player.npc_face_position = face_position
				else:
					var fref_node := _find_node_by_uuid(get_tree().get_root(), str(fref))
					if fref_node is Node3D:
						var face_world: Vector3 = (fref_node as Node3D).global_transform * face_position
						var face_parent = player.get_parent()
						player.npc_face_position = (face_parent as Node3D).global_transform.affine_inverse() * face_world \
								if face_parent is Node3D else face_world
					else:
						push_warning("npc_face_position: no Node3D found for uuid %s" % str(fref))
		"npc_arrived_ack":
			# The brain confirms it consumed the arrival notice. npc_arrived is a MERGED property (a
			# state, not an event), so it stays true until cleared — reset it and replicate the clear,
			# otherwise the next journey would start with a stale npc_arrived == true. See
			# _npc_notify_arrived.
			if player.is_npc:
				player.server_send_properties_to_client({"npc_arrived": false})
		"claim_reception":
			# A magasinier PNJ asks to take the reception role at a depot ({uuid: depot}). The depot
			# grants it only when free (atomic on this single-threaded server); the PNJ learns the
			# outcome from the replicated reception_owner property, so no reply is sent here.
			if player.is_npc:
				var depot_uuid = data.get("uuid", null)
				if depot_uuid != null and str(depot_uuid) != "":
					var depot := _find_node_by_uuid(get_tree().get_root(), str(depot_uuid))
					if depot != null and depot.has_method("try_claim_reception"):
						depot.try_claim_reception(player.client_uuid)
					else:
						push_warning("claim_reception: no depot with try_claim_reception for uuid %s" % str(depot_uuid))
		"release_reception":
			# The owning PNJ hands the reception role back (going off-shift, to a meal…). No-op on the
			# depot unless this PNJ is the current owner.
			if player.is_npc:
				var rel_uuid = data.get("uuid", null)
				if rel_uuid != null and str(rel_uuid) != "":
					var rel_depot := _find_node_by_uuid(get_tree().get_root(), str(rel_uuid))
					if rel_depot != null and rel_depot.has_method("release_reception"):
						rel_depot.release_reception(player.client_uuid)
		"dialog":
			# Queue only — _server_update_dialog owns the pacing and the actual send.
			var text = data.get("text", null)
			if text != null and str(text) != "":
				_dialog_queue.append(str(text))
		"action":
			print("action key pressed by player")
			if player.hands_item != null:
				# In hands (always solid now): release it (drop / bed-load). Shared with the auto-drop.
				_server_drop_carried_item()
			else:
				# Pick up the carriable the CLIENT aimed at: it sends the uuid under its crosshair, so we
				# grab exactly that one (our own server ray can be a hair off — pitch is throttled). (#124)
				var parent_node = _find_carriable(str(data.get("target_uuid", "")))
				var picked_up := false
				# Server-authoritative: same gate as the client — grabbable (not already carried) AND a
				# clear line of sight, so a thin wall can't be exploited to grab through it.
				var can_grab: bool = _stance == 0 and parent_node != null and parent_node.has_method("interact") \
						and parent_node.interact(player) and not _is_blocked_by_geometry(parent_node)
				if can_grab:
					# If it's secured in a vehicle bed, take it out of the load first (retrieval).
					var prev_parent = parent_node.get_parent()
					if prev_parent.has_method("release_cargo"):
						prev_parent.release_cargo(parent_node)
					# If it was stored in a shelf slot, free that slot (the crate is parented to the world,
					# not the shelf, so the release goes through the meta the shelf left on it, not prev_parent).
					if parent_node.has_meta("shelf_ref"):
						var stored_shelf = parent_node.get_meta("shelf_ref")
						if is_instance_valid(stored_shelf) and stored_shelf.has_method("release_slot"):
							stored_shelf.release_slot(parent_node)
					# Mount it RIGIDLY on the body: reparented under the player and pinned at
					# carry_mount_offset, it rides the player through the scene tree instead of being
					# steered there by velocity — no bobbing, no fighting the geometry, and a constant local
					# pose on the wire. Frozen KINEMATIC so it follows a moving parent (a STATIC frozen body
					# gets its world transform rewritten every physics frame instead), and made PHANTOM
					# (layer/mask 0) so a crate held against a wall can't shove its carrier or plough through
					# props. Both restored on drop.
					parent_node.set_meta("pre_carry_layer", parent_node.collision_layer)
					parent_node.set_meta("pre_carry_mask", parent_node.collision_mask)
					parent_node.collision_layer = 0
					parent_node.collision_mask = 0
					parent_node.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
					parent_node.freeze = true
					parent_node.linear_velocity = Vector3.ZERO
					parent_node.angular_velocity = Vector3.ZERO
					# Make sure its replication is active: a crate that sat in a bed may have had its
					# _physics_process paused, which would stop PropNet from replicating a later drop.
					parent_node.set_physics_process(true)
					parent_node.server_parent_change(player)
					# Each pickup starts unrotated; the wheel / middle-mouse then accumulate into it.
					_carry_basis = Basis.IDENTITY
					_place = {}  # the first physics tick fills it; nothing stale from the last carry
					parent_node.transform = Transform3D(_carry_basis, player.carry_mount_offset)
					#  send reparent to client
					parent_node.send_properties_to_client(player.client_uuid)
					player.hands_item = parent_node
					picked_up = true
					# Generic: mark carriables (e.g. a fault-less ore) as taken so nobody else can grab
					# them while in hands (issue #124).
					if parent_node.has_method("set_carried"):
						parent_node.set_carried(true)
					# Mark as carrying on all clients (perforator stows) (issue #124).
					player.server_send_properties_to_client({"carrying": true})
				if not picked_up:
					# Grabbed nothing: tell the owner to undo its optimistic stow (issue #124).
					player.server_send_properties_to_client({"carrying": false})

## Find a spawned mining rock by its uuid (server-side).
## Walk up from a raycast hit to the vehicle node it belongs to (group "vehicle"), else null.
func _find_vehicle(target_uuid: String) -> Node:
	if target_uuid == "":
		return null
	for v in get_tree().get_nodes_in_group("vehicle"):
		if "uuid" in v and str(v.uuid) == target_uuid:
			return v
	return null

func _find_mining_rock(rock_uuid: String) -> Node:
	if rock_uuid == "":
		return null
	for r in get_tree().get_nodes_in_group("miningrock"):
		if "uuid" in r and str(r.uuid) == rock_uuid:
			return r
	return null

## Find a player-spawned prop by uuid for the admin cleanup tool (server-side). Looks in the
## prop registry (any type) first, then the "carriable" group (rocks/boxes), so it works
## regardless of how the prop was registered.
func _find_deletable_prop(target_uuid: String) -> Node:
	if target_uuid == "":
		return null
	for ptype in NetworkOrchestrator.props_list.keys():
		if NetworkOrchestrator.props_list[ptype].has(target_uuid):
			var n = NetworkOrchestrator.props_list[ptype][target_uuid]
			if is_instance_valid(n):
				return n
	for n in get_tree().get_nodes_in_group("carriable"):
		if "uuid" in n and str(n.uuid) == target_uuid:
			return n
	# Fallback: scan the tree for ANY node carrying this uuid (depots / persisted props that
	# aren't in props_list nor the carriable group). The node has a collision body, so it IS
	# in the tree -> we find it and can free it (otherwise its collision lingers as a ghost).
	return _find_node_by_uuid(get_tree().get_root(), target_uuid)

# ------------------------------------------------------------------------------
# Dev spawn wheel (key T) — SERVER-AUTHORITATIVE. The client only sends a catalogue key; the scene,
# the object type, the celestial frame and the placement are all decided here.
# ------------------------------------------------------------------------------
## A wheel key arrived. Validate it against the catalogue and QUEUE it: placing a prop needs a ground
## raycast, and the physics space can only be queried during the physics step (this runs on a network
## message, outside it). _flush_spawn_queue does the work on the next tick.
func _spawn_from_catalog(key: String) -> void:
	if SpawnCatalog.entry(key).is_empty():
		print("🌱 Spawn refused: unknown catalogue key '%s'" % key)  # a tampered / stale client
		return
	_spawn_queue.append(key)

## Spawn everything the wheel asked for since the last tick (we are inside the physics step here).
func _flush_spawn_queue() -> void:
	while not _spawn_queue.is_empty():
		_spawn_prop(_spawn_queue.pop_front())

## Place ONE catalogue prop in front of the player and hand it to the network.
##
## The whole placement is computed in WORLD space (global_position, global_basis, up_direction — the
## server's own vectors) and converted to the parent's frame ONCE, at the end. Mixing a LOCAL position
## with WORLD axes — what the old client-side code did — silently skews the result as soon as the
## parent frame is rotated, which the planet/city always is.
func _spawn_prop(key: String) -> void:
	var entry: Dictionary = SpawnCatalog.entry(key)
	if entry.is_empty():
		return
	var forward: Vector3 = -player.global_basis.z  # where the player faces, in world space
	var aim: Vector3 = player.global_position + forward * float(entry["distance"])
	var spawn_world: Vector3 = aim
	var basis: Basis = player.global_basis
	# On a planet: drop the prop ON the ground, standing up along the local vertical. In zero g there
	# is no ground and no vertical: leave it floating in front of the eyes, facing as we do.
	var gravity_area: Node3D = player.get_current_gravity_parent()
	if gravity_area != null:
		var up: Vector3 = player.up_direction
		var ignore: Array[RID] = [player.get_rid()]  # don't let our own body catch the ray
		var ground: Variant = PropSpawn.ground_point(
				player.get_world_3d().direct_space_state, aim, up, GROUND_SEARCH, ignore)
		if ground != null:
			spawn_world = (ground as Vector3) + up * float(entry["origin_height"])
		else:
			# Nothing under the crosshair (a hole, a cliff edge): keep the prop at our own height
			# rather than dropping it into the void.
			spawn_world = aim + up * float(entry["origin_height"])
		basis = Globals.align_with_y(Transform3D(player.global_basis, Vector3.ZERO), up).basis
	# Express the placement in the frame of the planet/city we stand on: a prop left in world
	# coordinates is pinned in space while its planet moves away at ~3e10 (it drifts out of sight).
	var net_parent: Node = PropSpawn.find_net_parent(player)
	var local_pos: Vector3 = PropSpawn.to_parent_local(net_parent, spawn_world)
	var local_rot: Vector3 = _to_parent_rotation(net_parent, basis)
	NetworkOrchestrator.spawn_prop_authoritative({
		"type": str(entry["type"]),
		"uuid": UUID_UTIL.v4(),
		"position": {"x": local_pos.x, "y": local_pos.y, "z": local_pos.z},
		"rotation": {"x": local_rot.x, "y": local_rot.y, "z": local_rot.z},
		"scenename": str(entry["scene"]).trim_prefix("res://"),
		"parent_id": PropSpawn.net_parent_uuid(net_parent),
	})
	print("🌱 Spawn '%s' (%s) for %s" % [key, entry["type"], player.client_uuid])

## A WORLD orientation expressed in the parent's frame, as the euler angles the network carries.
func _to_parent_rotation(net_parent: Node, world_basis: Basis) -> Vector3:
	if net_parent is Node3D:
		var parent_basis: Basis = (net_parent as Node3D).global_basis
		return (parent_basis.inverse() * world_basis).orthonormalized().get_euler()
	return world_basis.orthonormalized().get_euler()

## Recursive search for a node whose `uuid` matches (server-side helper).
func _find_node_by_uuid(node: Node, target_uuid: String) -> Node:
	if "uuid" in node and str(node.uuid) == target_uuid:
		# The uuid now lives on the PropSync component (a plain Node); callers
		# want the spatial host, so hop to its Node3D parent.
		if node is PropSync:
			return node.get_parent()
		return node
	for child in node.get_children():
		var found: Node = _find_node_by_uuid(child, target_uuid)
		if found != null:
			return found
	return null

## Find a carriable (group "carriable") by its uuid (server-side). Used to pick up
## exactly the object the client aimed at. (#124)
func _find_carriable(target_uuid: String) -> Node:
	if target_uuid == "":
		return null
	for n in get_tree().get_nodes_in_group("carriable"):
		if "uuid" in n and str(n.uuid) == target_uuid:
			return n
	return null

func _reparent_children_of_prop(prop: Node) -> void:
	if prop == null or not is_instance_valid(prop):
		return
	var parent = prop.get_parent()
	for child in prop.get_children():
		if is_instance_valid(child):
			if child.has_method("client_parent_change"):
				child.server_parent_change(parent)
			elif child.has_method("_safe_reparent_and_sync"):
				child._safe_reparent_and_sync(parent)
			else:
				print("WARNING: child %s of prop %s has no client_parent_change method" % [child.name, prop.name])


## Server physics tick — applies replicated input, gravity, carry float + throttled carry prompt, then
## replicates the position. Runs on THIS role's own child node, so the engine calls it only on the
## dedicated server. Reads/writes the shared body through `player`; carry/LOS helpers still live on the
## Player facade for now (2d) and are reached via `player.`.
func _physics_process(delta: float) -> void:
	if not PropNet.PROF:
		_physics_process_impl(delta)
		return
	var _t0: int = Time.get_ticks_usec()
	_physics_process_impl(delta)
	PropNet.prof_player_usec += Time.get_ticks_usec() - _t0
	PropNet.prof_player_calls += 1

func _physics_process_impl(delta: float) -> void:
	var _tp: int = Time.get_ticks_usec() if PropNet.PROF else 0
	_flush_spawn_queue()  # the wheel's spawns wait for the physics step: they need a ground raycast
	_process_stance_request()  # apply a queued crouch/stand here: the headroom ray needs the space state
	_server_update_carried_item(delta)
	if not player.is_npc:
		# The E-prompt only exists for a human owner's HUD; for an NPC it would still cost a forced
		# raycast every 0.1 s per NPC (measured hot with many NPCs), replicated to nobody.
		_server_update_carry_prompt(delta)
	if PropNet.PROF:
		PropNet.prof_p_pre_usec += Time.get_ticks_usec() - _tp
	_server_update_gravity_frame(delta)  # before every early-return below: EVA is exactly who leaves
	if _hold_until_ground(delta):
		return  # nothing under us yet: hold still rather than fall through
	if _vault_cooldown > 0.0:
		_vault_cooldown = maxf(0.0, _vault_cooldown - delta)
	if _vaulting:
		_server_update_vault(delta)  # a climb is in progress: it owns the body until it lands
		return
	if _stepping:
		_server_update_step(delta)  # a smooth step-up glide is in progress
		return
	# Before the seat / NPC early-returns below: an NPC returns out of this function, and an NPC is
	# precisely who does the talking.
	_server_update_dialog(delta)
	if player.piloting and is_instance_valid(player._seat_node):
		# Seated in a vehicle: ride its seat. Server-authoritative; the emitted position replicates so
		# the player follows the vehicle (camera rides too).
		player._ride_seat(player._seat_node)
		player.new_input_from_server = false
		player.emit_move()
		return

	# NPC: server-driven pathfinding replaces client input. Runs in its own branch because an NPC never
	# sets new_input_from_server (that flag only fires for real replicated client input).
	if player.is_npc:
		_npc_physics_process(delta)
		return

	if player.new_input_from_server:
		player.input_direction = player.input_from_server["input_direction"]
		player.rotation = player.input_from_server["rotation"]  # LOCAL rotation (planet-relative), see player_client send
		if player.piloting:
			player.input_direction = Vector2.ZERO  # seated in a vehicle: no walking

	if player.eva_mode:
		# EVA free-flight (dev): fly the body where the camera looks, gravity off, collision off.
		# Skips the whole walk/gravity/idle-sleep path below, then replicates like the normal tick.
		_server_eva_move(delta)
		player.new_input_from_server = false
		player.emit_move()
		return

	# Server-side "sleep" for settled players: once quasi-still for ~0.5 s, run the full move_and_slide
	# only every 10th tick (6 Hz keeps the floor contact honest). Any input/velocity resets the counter.
	if not player.new_input_from_server and player.input_direction == Vector2.ZERO \
			and player.is_on_floor() and player.velocity.length_squared() < 0.0001:
		_idle_settled_ticks += 1
		if _idle_settled_ticks > 30 and (_idle_settled_ticks % 10) != 0:
			return
	else:
		_idle_settled_ticks = 0

	var parent_gravity_area: Area3D = player.gravity_parents.back() if not player.gravity_parents.is_empty() else null

	if parent_gravity_area:
		if parent_gravity_area.gravity_point:
			player.up_direction = parent_gravity_area.global_position.direction_to(player.global_position)
		else:
			player.up_direction = parent_gravity_area.global_basis.y
		player.gravity = player._compute_gravity(parent_gravity_area)
		player.motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	else:
		# 0g movement
		player.gravity = 0.0
		player.camera_pivot.rotation.x = 0
		player.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
		var dir = Vector3(player.input_direction.x, 0, player.input_direction.y)
		player.player_thruster_force = 10
		player.velocity += player.global_basis * dir * player.player_thruster_force * delta
		player.velocity *= 0.98

	var move_direction = (player.global_transform.basis * Vector3(player.input_direction.x, 0, player.input_direction.y)).normalized()

	# Auto-vault: standing still-on-floor and walking forward into a low obstacle / ledge -> climb onto it.
	# Server-authoritative; runs before the jump/gravity/move so the normal step never fights the slide.
	var _tv: int = Time.get_ticks_usec() if PropNet.PROF else 0
	var _vault_started: bool = player.is_on_floor() and _try_start_vault()
	if PropNet.PROF:
		PropNet.prof_p_vault_usec += Time.get_ticks_usec() - _tv
	if _vault_started:
		_server_update_vault(delta)
		return

	# Owner-driven gait: sprint (Shift held) or the mouse-wheel-chosen walk speed.
	var speed = player.sprint_speed if _sprint_held else _walk_speed_target
	if _stance == 1:  # crouched: capped to crouch_speed (no sprint)
		speed = minf(speed, player.crouch_speed)
	elif _stance == 2:  # prone: even slower
		speed = minf(speed, player.prone_speed)
	if player.mining_tool.is_aiming:
		speed *= player.mining_tool.aim_speed_factor  # slowed down in aim mode
	if player.mining_tool.is_perforating:
		speed = 0.0  # frozen during perforation
	if player.hands_item != null:
		speed *= player.carry_speed_factor  # carrying an ore slows you down (issue #124)

	# GDD: no air control. Only the grounded branch below steers the horizontal velocity; once airborne
	# we leave it alone, so a jump carries the run-up momentum and its distance follows the take-off
	# speed. The airborne case used to ADD move_direction * speed * delta every frame with no target and
	# no cap — unlike the grounded move_toward, which is bounded by `speed` — so every sprint-jump banked
	# about +5 m/s for good and repeated hops climbed to the 60 m/s anti-tunnelling ceiling below.
	if player.is_on_floor():
		# Accelerate/decelerate the HORIZONTAL velocity toward the target at `acceleration` (m/s²), so the
		# player ramps up to speed and coasts to a stop instead of snapping. The vertical component
		# (gravity / jump, along up_direction) is preserved untouched.
		var up: Vector3 = player.up_direction
		var vertical: Vector3 = up * player.velocity.dot(up)
		var target: Vector3 = move_direction * speed if player.input_direction else Vector3.ZERO
		var horizontal: Vector3 = (player.velocity - vertical).move_toward(target, player.acceleration * delta)
		player.velocity = horizontal + vertical

	if player.is_on_floor() and player.is_jumping:
		player.velocity += player.up_direction * player.jump_height * player.gravity
		player.is_jumping = false
		# Tell the clients the jump actually HAPPENED (a request while airborne is ignored above, and
		# would otherwise still be heard). They play the jump sound on it — ours and the other players'.
		# The counter is what makes it an EVENT: "action" is a replicated state, delta-compressed, so
		# sending the same "jump" twice in a row would be dropped as "unchanged" and the second jump
		# would be silent. A value that always changes always gets through.
		_jump_count += 1
		player.server_send_properties_to_client({"action": "%s:%d" % [JUMP, _jump_count]})
	# Add gravity ALWAYS (even on the floor) so the capsule stays pressed onto the terrain trimesh and
	# is_on_floor() stays true — gating it on "not is_on_floor()" caused a ~1 cm idle "dancing".
	else:
		player.velocity -= player.up_direction * player.gravity * 2.0 * delta
		player.is_jumping = false

	# Cap fall speed to avoid tunneling through the thin trimesh terrain (move_and_slide has no CCD).
	var _terminal_velocity: float = 60.0
	if player.velocity.length() > _terminal_velocity:
		player.velocity = player.velocity.normalized() * _terminal_velocity

	# LOW obstacle right ahead (below the vault threshold): glide the body onto it (Godot's CharacterBody3D
	# won't step up on its own). Taller obstacles are the vault's job. Started here, then driven by
	# _server_update_step for a smooth, speed-independent climb.
	var _ts: int = Time.get_ticks_usec() if PropNet.PROF else 0
	var _step_started: bool = player.is_on_floor() and player.input_direction != Vector2.ZERO \
			and _try_start_step_up(move_direction)
	if PropNet.PROF:
		PropNet.prof_p_step_usec += Time.get_ticks_usec() - _ts
	if _step_started:
		_server_update_step(delta)
		return

	var _tm: int = Time.get_ticks_usec() if PropNet.PROF else 0
	player.move_and_slide()
	if PropNet.PROF:
		PropNet.prof_p_move_usec += Time.get_ticks_usec() - _tm
		# A settled contact resolves in one iteration; an unstable one makes move_and_slide re-cast up
		# to max_slides times, which is the shape this cost has (0.18 ms -> 3.30 ms when walking).
		PropNet.prof_slide_count += player.get_slide_collision_count()
		PropNet.prof_slide_ticks += 1

	# Landing: the instant we are back on the floor after being airborne, emit a "land:<n>" event so
	# clients end the jump loop crisply (it can't overstay). The counter defeats delta compression.
	var grounded_now: bool = player.is_on_floor()
	if grounded_now and _was_airborne:
		_land_count += 1
		player.server_send_properties_to_client({"action": "land:%d" % _land_count})
	_was_airborne = not grounded_now

	# Safety net: catch a fast fall that tunneled clearly below the planet surface.
	if parent_gravity_area and parent_gravity_area.gravity_point \
			and parent_gravity_area.name == "PlanetGravity":
		_catch_if_below_surface(parent_gravity_area)

	player.update_last_basis()
	player.new_input_from_server = false

	var _te: int = Time.get_ticks_usec() if PropNet.PROF else 0
	player.emit_move()
	if PropNet.PROF:
		PropNet.prof_p_emit_usec += Time.get_ticks_usec() - _te

## Release the body from a planet's frame once its gravity has REALLY been gone (Player.ZERO_G_GRACE),
## and hand it to the world frame — the planet's own parent, the universe root, where the star sits
## too, so this is already the star's frame. The mirror of Player's gravity-ENTERED branch, which
## adopts a body only when it arrives from the world: together they are reference-frame switching at
## the sphere of influence, the shape space flight will need.
##
## Without it, a body that flies away stays a child of the planet and is dragged by its SPIN — about
## 500 m/s of sideways pull at 1000 km up, which is not what a free body does. (The orbit drags it
## too, but that part is roughly right: a body near a planet does share its orbital motion.)
##
## Checked as STATE every tick, never on the area_exited event. A reparent drops and re-enters every
## area for a frame or two, and acting on that blip would publish a world position (~3e10) announced
## as local to the planet: one dropped message and the body is flung across the system.
## The parent test is the other half of the guard — a seated driver hangs from the vehicle and a
## player indoors from the building, and neither of them is leaving anything.
## Hold a freshly created body still until the terrain under it actually exists. Returns true while
## it is being held, and the caller must then do nothing else this tick.
##
## The server builds terrain collision chunk by chunk, on worker threads, and only around bodies that
## already exist — so there is unavoidably a window after creation where there is nothing underneath.
## Released into it, a body meets only the planet-wide fallback shells 100-200 m BELOW the playable
## surface: it falls, _catch_if_below_surface teleports it back to the theoretical surface without any
## real contact (so is_on_floor() stays false), gravity resumes next frame, and it falls again —
## forever. That loop is what "spawned in the air, bouncing in the void" actually was.
##
## Only the FIRST moments are gated. Once the ground has been seen, it is never checked again: a body
## walking off the edge of loaded terrain is a different problem, and the fallback shells plus
## _catch_if_below_surface are what handle that.
##
## It cannot deadlock: pinning walks players_list and asks for the chunk under each of them whether
## they move or not, so being held does not stop the ground being built. And SPAWN_GROUND_TIMEOUT
## releases the body regardless — a player frozen forever would be worse than the bug being fixed.
func _hold_until_ground(delta: float) -> bool:
	if _ground_seen:
		return false
	var terrain: PlanetTerrain = null
	var walk: Node = player.get_parent()
	while walk != null:
		if walk is Planet:
			terrain = (walk as Planet).planet_terrain
			break
		walk = walk.get_parent()
	if terrain == null:
		# Not on a celestial body at all (EVA, a body in transit): nothing to wait for.
		_ground_seen = true
		return false
	if terrain.has_collision_under(player.global_position):
		_ground_seen = true
		return false
	_ground_wait += delta
	if _ground_wait >= SPAWN_GROUND_TIMEOUT:
		push_warning("[Spawn] %s: no terrain collision after %.0f s, releasing anyway"
				% [player.client_uuid, _ground_wait])
		_ground_seen = true
		return false
	# Held: no gravity, no move_and_slide, no velocity to carry over when we are let go.
	player.velocity = Vector3.ZERO
	return true


func _server_update_gravity_frame(delta: float) -> void:
	if not player.gravity_parents.is_empty():
		player._no_gravity_time = 0.0
		_had_gravity = true
		return
	# ⚠️ You cannot LEAVE a gravity well you were never in. At spawn the AreaDetector needs a few
	# physics frames to report its overlaps, so gravity_parents is empty to begin with — and without
	# this guard a body was released into the world frame seconds after spawning, INDOORS, having gone
	# nowhere. It then sat outside the planet's subtree while the planet carried on at 33 km/s, which
	# reads in game as being flung into the air and left bobbing in the void.
	if not _had_gravity:
		return
	player._no_gravity_time += delta
	if player._no_gravity_time < player.ZERO_G_GRACE:
		return
	# Riding something means the ride owns our frame: it is the VEHICLE that would be leaving, not us.
	if player.piloting or player._in_vehicle_bed != null:
		return
	var world: Node = _world_frame_above(player.get_parent())
	if world != null:
		print("[Frame] %s released to the world: %.2f s without gravity, was under '%s'" % [
				player.client_uuid, player._no_gravity_time, player.get_parent().name])
		player.call_deferred("_safe_reparent_and_sync", world)


## What to hand a body to when it leaves the sphere of influence it is standing in: the parent of the
## nearest celestial ancestor of [param frame]. Null when there is no such ancestor — we are already
## in the world frame, or under something that is not a celestial body.
##
## Walks UP because a body is rarely a direct child of its planet: leaving the spawn building parents
## it to the CITY, itself a prop on the planet. Testing the direct parent found nothing and the body
## stayed glued to the planet all the way into space.
##
## Nesting falls out for free and is correct: from a body on a MOON the walk stops at the moon and
## returns the moon's parent, its planet — leaving a moon's SOI puts you in the planet's, not in deep
## space.
static func _world_frame_above(frame: Node) -> Node:
	var node: Node = frame
	while node != null:
		if node is Planet:
			# Since the ORIGIN REBASE a planet sits at the origin of its OWN physics world, held by a
			# SubViewport (Server.create_planet). Its parent is therefore that viewport, not the universe
			# root — and stepping a single level would leave a body that has just LEFT the planet inside
			# the planet's world, which is the one place it must not be.
			var above: Node = node.get_parent()
			while above is SubViewport:
				above = above.get_parent()
			return above
		node = node.get_parent()
	return null


## Auto-vault: standing and walking forward into a low obstacle or a climbable ledge, start a scripted
## climb-onto and tell clients which clip to play. Returns true when a vault begins. Gameplay guards live
## here; the geometry (trace-based mantle) is the shared VaultProbe, so the debug HUD reads the SAME probe.
func _try_start_vault() -> bool:
	if _vaulting or _vault_cooldown > 0.0 or _stance != 0:
		return false  # only from a standing, settled state
	if player.hands_item != null or player.is_jumping or not player.is_on_floor():
		return false  # not with hands full, mid-jump, or off the ground
	if player.mining_tool.is_perforating:
		return false
	if player.input_direction == Vector2.ZERO or player.input_direction.y > -0.3:
		return false  # only while actually walking forward (get_vector: forward = y < 0)
	var p: Dictionary = VaultProbe.probe(player, _stance_height(0))  # shared geometry (see the debug HUD)
	if not bool(p["ok"]):
		return false
	var key: String = p["key"]
	_vault_duration = player.vault_duration
	if key == "climb_2m":
		_vault_duration = player.climb2_duration
	elif key == "climb_1m":
		_vault_duration = player.climb1_duration
	var frame: Node = player.get_parent()
	_vault_start = player.position  # parent-frame (local); the slide stays robust to a moving planet frame
	var landing: Vector3 = p["landing"]
	_vault_end = (frame as Node3D).to_local(landing) if frame is Node3D else landing
	# Vault-OVER (SafetyVault) arcs UP over the obstacle then back down to the far-side ground; the climbs
	# go straight to the top (no arc). The arc is added along the body's up, expressed in the parent frame.
	if key == "vault":
		_vault_arc = float(p["height"]) + player.vault_arc_margin
		var up_world: Vector3 = player.up_direction
		if frame is Node3D:
			_vault_up_local = ((frame as Node3D).global_transform.basis.inverse() * up_world).normalized()
		else:
			_vault_up_local = up_world.normalized()
	else:
		_vault_arc = 0.0
	_vault_time = 0.0
	_vaulting = true
	_vault_count += 1
	# "vault:<key>:<height>:<n>" — the height lets the animator align the pose to the obstacle (see
	# CharacterAnimator vault_puppet_offset); the counter defeats delta compression, like the jump.
	player.server_send_properties_to_client({"action": "vault:%s:%.2f:%d" % [key, float(p["height"]), _vault_count]})
	return true

## Advance the scripted climb: slide the body from its start to the ledge landing over _vault_duration,
## gravity/input/collision suspended (the position is written directly, like EVA). Replicates the pose each
## tick; on arrival, releases control and starts the cooldown. The clip plays client-side off the event.
func _server_update_vault(delta: float) -> void:
	_vault_time += delta
	var s: float = clampf(_vault_time / maxf(_vault_duration, 0.01), 0.0, 1.0)
	var pos: Vector3 = _vault_start.lerp(_vault_end, smoothstep(0.0, 1.0, s))
	if _vault_arc > 0.0:
		pos += _vault_up_local * (_vault_arc * sin(PI * s))  # up over the obstacle, back to ground far side
	player.position = pos
	player.velocity = Vector3.ZERO
	_emit_move()
	if s >= 1.0:
		_vaulting = false
		_vault_cooldown = player.vault_cooldown

## Detect a LOW obstacle we walk into (below vault_min_height, so no vault fires) and, if there is a
## walkable top within that height with clearance above, START a short glide onto it (see
## _server_update_step). Returns true if a step-up began. Reuses the vault threshold (no gap between "walk
## up" and "vault") and the shared _solid_ray. The short step_up_reach keeps it from firing before the step.
func _try_start_step_up(move_dir: Vector3) -> bool:
	var up: Vector3 = player.up_direction
	var fwd: Vector3 = move_dir - up * move_dir.dot(up)
	if fwd.length() < 0.01:
		return false
	fwd = fwd.normalized()
	var feet: Vector3 = player.global_position
	var reach: Vector3 = fwd * player.step_up_reach
	var max_step: float = player.vault_min_height  # below the vault threshold = a step you walk up
	# The face of a low obstacle right at the ankles?
	var low: Dictionary = _solid_ray(feet + up * 0.05, feet + up * 0.05 + reach)
	if low.is_empty():
		return false
	# Clear at step height (else it is tall -> the vault or a wall handles it).
	if not _solid_ray(feet + up * max_step, feet + up * max_step + reach).is_empty():
		return false
	# Probe the top JUST PAST the face (from where the low ray hit), so a THIN obstacle works too — a fixed
	# forward offset overshoots a shallow step and lands on the ground behind it, finding no top.
	var face_dist: float = (Vector3(low["position"]) - feet).dot(fwd) + 0.05
	var over: Vector3 = fwd * face_dist
	var top: Dictionary = _solid_ray(feet + up * max_step + over, feet + over + up * 0.02)
	if top.is_empty() or Vector3(top["normal"]).dot(up) < 0.6:
		return false  # no top, or too steep to stand on
	var h: float = (Vector3(top["position"]) - feet).dot(up)
	if h <= 0.03 or h > max_step:
		return false
	# Land lifted by h and nudged forward past the face (speed-independent — a lift alone stalled at a slow
	# walk, waiting on horizontal velocity to clear the edge). Glided, not teleported (see below).
	var landing: Vector3 = feet + up * (h + 0.03) + fwd * face_dist
	var frame: Node = player.get_parent()
	_step_start = player.position
	_step_end = (frame as Node3D).to_local(landing) if frame is Node3D else landing
	_step_time = 0.0
	_stepping = true
	return true

## Advance the smooth step-up glide: ease the body from its start to the step top over step_up_duration.
## No clip and no cooldown (stairs climb freely); the velocity is left untouched, so walking resumes with
## its momentum the instant the glide ends.
func _server_update_step(delta: float) -> void:
	_step_time += delta
	var s: float = clampf(_step_time / maxf(player.step_up_duration, 0.01), 0.0, 1.0)
	player.position = _step_start.lerp(_step_end, smoothstep(0.0, 1.0, s))
	_emit_move()
	if s >= 1.0:
		_stepping = false

## Network parent to attach to every replicated move while the origin rebase has this player
## parented DIRECTLY to a Planet (server.gd create_player routes unparented spawns there; every
## Horizon-driven parent — apartment, vehicle seat, teleport target — is a non-Planet node).
##
## Sent on EVERY move, exactly like PropNet re-sends position+parent_id for carried props: the
## client's player_update applies parent_id + the parent-LOCAL position ATOMICALLY (reparent +
## net_set_local_target in the same payload), and repeating it makes Horizon's record converge
## even if one message is lost mid-registration. The two broken alternatives are documented
## history: sending the parent_id ONCE at spawn lost the race with Horizon's registration (GORC
## then read planet-local coords as universe → empty world), and sending ABSOLUTE positions with
## parent "" collided with the GORC zone-enter that reparents the client under the planet (the
## absolute vector was applied planet-LOCAL → player 3.3e10 m into deep space; measured both,
## 2026-08-19).
func _net_parent_uuid():
	var parent: Node = player.get_parent()
	if parent is Planet:
		return str((parent as Planet).uuid)
	return null

## Replicate the body's current pose to clients (server-authoritative move). Shared by the scripted glides
## (vault, step-up) so they emit exactly like the normal tick.
func _emit_move() -> void:
	player.new_input_from_server = false
	# NOTE: this used to send global_rotation while every other sender sent the LOCAL rotation the
	# client contract expects (see Player.net_set_target) — identical only while the parent's basis is
	# identity, wrong the moment it is not. Going through Player.emit_move() removes the divergence.
	player.emit_move()

## EVA free-flight integration (dev test aid). Moves the body straight along the camera's look
## direction at eva_speed by writing the position directly — NO move_and_slide, so hundreds of m/s
## can't tunnel the thin terrain trimesh or trip the below-surface catch, and no gravity is applied
## (this tick returns before the walk path). Same input mapping as walking, but in the CAMERA frame
## so looking up/down climbs/dives — the server holds the replicated camera pitch on camera_pivot.
## Stops crisply with no input, to line up a steady view of a body's day/night face.
func _server_eva_move(delta: float) -> void:
	var look: Basis = player.camera_pivot.global_transform.basis
	var wish: Vector3 = look * Vector3(player.input_direction.x, 0.0, player.input_direction.y)
	if wish.length_squared() > 0.0001:
		player.velocity = wish.normalized() * player.eva_speed
	else:
		player.velocity = Vector3.ZERO
	player.global_position += player.velocity * delta

## NPC server tick: keep the body on the floor under gravity, then steer it along the nav path toward
## player.npc_go_to_position (baking walkable coverage around it on demand) with stuck recovery. Drives
## the body from the NavigationAgent3D instead of replicated client input. Gravity-frame aware: "down"
## is player.up_direction (radial on a planet), so steering happens in the ground plane, not world XZ.
func _npc_physics_process(delta: float) -> void:
	# Server-side "sleep" for settled idle NPCs — the same throttle real players get (see the
	# idle-settled block in _physics_process): once an NPC has nothing to do (no goal, no pending
	# facing turn, resting on the floor, no residual velocity), run the full gravity + move_and_slide
	# only every 10th tick (6 Hz keeps the floor contact honest). Like the player path, the check runs
	# BEFORE this tick's gravity is applied, so on skipped ticks the velocity stays at its settled ~0.
	if player.npc_go_to_position == null and player.npc_face_position == null \
			and player.is_on_floor() and player.velocity.length_squared() < 0.0001:
		_npc_idle_ticks += 1
		if _npc_idle_ticks > 30 and (_npc_idle_ticks % 10) != 0:
			return
	else:
		_npc_idle_ticks = 0
	# Gravity, mirroring the non-NPC setup so the NPC settles onto whatever body it stands on.
	var grav_area: Node3D = player.get_current_gravity_parent()
	if grav_area:
		if grav_area.gravity_point:
			player.up_direction = grav_area.global_position.direction_to(player.global_position)
		else:
			player.up_direction = grav_area.global_basis.y
		player.gravity = player._compute_gravity(grav_area)
	else:
		player.up_direction = Vector3.UP
		player.gravity = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	# Stand the NPC up along its local up. Nothing else does it: orient_player() is called by the
	# OWNING CLIENT for its own body (player_client.gd), and the resulting rotation is what every
	# other machine replicates — but an NPC has no owning client, so nobody was ever righting it.
	#
	# The NPC service sends a plain heading, which is correct in the planet's own frame and completely
	# wrong on the ground: the city sits on the flank of the sphere, 5640 m up and far from the
	# planet's Y axis, so a heading-only rotation leaves the body LYING FLAT on the floor. That is the
	# whole of the "the magasiniers are lying down" bug — a perfectly oriented body, in the wrong frame.
	#
	# align_with_y keeps basis.z, so the heading the service asked for survives: only the vertical is
	# rebuilt. Same lerp as the on-foot path, so an NPC rights itself exactly as a player does.
	player.orient_player()
	# Apply gravity ALWAYS (even on the floor) so the capsule stays pressed onto the terrain trimesh and
	# is_on_floor() stays true — this is the SAME fix the on-foot path uses (see the "Add gravity ALWAYS"
	# block above). Gating gravity on "not is_on_floor()" and zeroing the downward velocity on the floor
	# makes a near-zero-motion move_and_slide lose floor contact for a tick, drop one dose of gravity,
	# re-contact, zero again — the ~1 cm idle "dance" that made every NPC bob in place forever.
	player.velocity -= player.up_direction * player.gravity * 2.0 * delta

	var _vertical: Vector3 = player.up_direction * player.velocity.dot(player.up_direction)

	# No destination: bleed off horizontal speed, keep gravity, turn toward a
	# pending facing goal, replicate.
	if player.npc_go_to_position == null:
		var _horiz: Vector3 = (player.velocity - _vertical).move_toward(Vector3.ZERO, _NPC_WALK_SPEED)
		player.velocity = _horiz + _vertical
		player.move_and_slide()
		_npc_update_face_target(delta)
		player.emit_move()
		return

	# A NEW goal invalidates everything the watchdog has learned about the last one (and any detour it
	# picked for it), so notice the change before anything else reads that state.
	if _npc_goal_seen == null or _npc_goal_seen != player.npc_go_to_position:
		_npc_goal_seen = player.npc_go_to_position
		_npc_reset_recovery()

	# Make sure there is baked coverage around / ahead of us to path on.
	_ensure_npc_nav_region()
	# Drop the detour once it has served its purpose, so we aim at the real goal again.
	_npc_update_detour(delta)

	if _NPC_DEBUG:
		_npc_debug_timer -= delta
		if _npc_debug_timer <= 0.0:
			_npc_debug_timer = 2.0
			_npc_debug_report()

	# Re-issue the route periodically: the mesh may still have been baking last time, the goal can move,
	# and the bake box re-centres as we travel.
	_npc_path_retry_timer -= delta
	if _npc_path_retry_timer <= 0.0:
		_npc_path_retry_timer = 1.0
		_npc_repath()

	var _next = _npc_next_path_point()
	if _next == null:
		# No more waypoints. This fires BOTH on real arrival AND when there is simply no route yet (mesh
		# still baking / goal genuinely unreachable), so we can't treat it as "arrived" on its own — gate
		# on the actual ground-plane distance to the goal before notifying.
		var _arrived: bool = _npc_ground_dist_to_goal() <= _NPC_ARRIVED_DIST
		if _arrived:
			_npc_notify_arrived()
		# Either way, bleed off horizontal speed and hold (gravity still owns the vertical axis).
		var _idle: Vector3 = (player.velocity - _vertical).move_toward(Vector3.ZERO, _NPC_WALK_SPEED)
		player.velocity = _idle + _vertical
		player.move_and_slide()
		# NOT arrived and no route: the NPC is parked short of a goal it cannot path to — the exact case
		# the watchdog exists for, and the one it used to miss entirely because this branch returned
		# before ever reaching the _npc_update_stuck call at the end of the walking path.
		if not _arrived:
			_npc_update_stuck(delta)
		_npc_emit_move()
		return

	# Steer toward the next path point in the ground plane; gravity owns the vertical axis.
	var _to_dest: Vector3 = (_next as Vector3) - player.global_position
	_to_dest -= player.up_direction * _to_dest.dot(player.up_direction)
	var _direction := _to_dest.normalized()
	_npc_face(_direction, delta)
	player.velocity = _direction * _NPC_WALK_SPEED + _vertical
	player.move_and_slide()

	_npc_update_stuck(delta)
	player.emit_move()

## NPC pathing diagnostics — prints every 2 s while an NPC has a goal it has not reached (mesh/island
## reachability, bake box, reparent frames...). Costs several nav queries per report: keep off outside
## debugging sessions.
const _NPC_DEBUG: bool = false

## Dump why the NPC is (not) pathing. The decisive numbers are `target off navmesh` — the target is not
## on any baked polygon, so map_get_path can only return a PARTIAL path and the NPC stops at the nearest
## reachable spot (a wall) — and `up vs +Y`: Recast always bakes assuming +Y is up IN THE REGION'S FRAME,
## so on a planet, ground far from where radial up meets +Y rasterizes as an unwalkable slope.
func _npc_debug_report() -> void:
	var map: RID = _npc_map()
	var target: Vector3 = _npc_target_global()
	var near_npc := _npc_from_nav(NavigationServer3D.map_get_closest_point(map, _npc_to_nav(player.global_position)))
	var near_target := _npc_from_nav(NavigationServer3D.map_get_closest_point(map, _npc_to_nav(target)))
	var polys: int = 0
	if _npc_nav_mesh != null:
		polys = _npc_nav_mesh.get_polygon_count()
	var path := NavigationServer3D.map_get_path(map, _npc_to_nav(player.global_position), _npc_to_nav(target), true)
	var path_end_gap := -1.0
	if path.size() > 0:
		path_end_gap = _npc_from_nav(path[path.size() - 1]).distance_to(target)
	var parent_name: String = str(player.get_parent().name) if player.get_parent() else "<none>"
	# Recast's up is +Y IN THE FRAME IT BAKES IN — so measure against the bake frame's +Y, not the world's.
	# (Measuring against Vector3.UP is meaningless here: the planet is tilted in the universe, so it reads
	# ~65 deg even when the bake frame is perfectly aligned with the ground.)
	var up_err: float = 0.0
	if _npc_nav_frame != null:
		up_err = rad_to_deg(player.up_direction.angle_to(_npc_nav_frame.global_transform.basis.y))
	# Is the goal actually inside the region we baked? If not it lands on another region, or none, and
	# the path query returns a stub.
	var goal_in_box := "n/a"
	if _npc_nav_frame != null and _npc_nav_mesh != null:
		goal_in_box = "yes" if _npc_nav_mesh.filter_baking_aabb.has_point(_npc_to_nav(target)) else "NO <-- goal outside our bake box"
	print("    goal inside our bake box: %s" % goal_in_box)
	print("[NPC %s] parent=%s  goal(parent-local)=%s  goal(global)=%s" % [
			player.name, parent_name, player.npc_go_to_position, target])
	print("    npc_pos=%s  dist_to_goal=%.2f  regions_in_map=%d  our_navmesh_polys=%d" % [
			player.global_position, player.global_position.distance_to(target),
			NavigationServer3D.map_get_regions(map).size(), polys])
	print("    navmesh under NPC : %.2f m away   |   navmesh under GOAL: %.2f m away %s" % [
			near_npc.distance_to(player.global_position), near_target.distance_to(target),
			"  <-- GOAL IS OFF THE NAVMESH (partial path -> stops at wall)" if near_target.distance_to(target) > 1.0 else ""])
	# What is the NPC physically standing on, and where is its nearest navmesh relative to that? A mesh
	# well BELOW the NPC means the surface it stands on produced NO navmesh (no collider on it, so a
	# STATIC_COLLIDERS bake cannot see it) and the NPC snapped down to whatever lies underneath — which,
	# inside a building, is a patch fenced in by that building's own shell and >agent_max_climb (0.4 m)
	# below the doorway, hence an island it can never leave.
	# Raycast rather than slide collisions: a resting body reports no slides, so slides read "airborne"
	# for a stationary NPC. This asks the physics world directly what surface is under it, and whether
	# that surface is even in the layer mask the bake voxelizes.
	var _floor_desc := "<nothing within 3 m>"
	var _space = player.get_world_3d().direct_space_state
	var _q := PhysicsRayQueryParameters3D.create(
			player.global_position + player.up_direction * 0.5,
			player.global_position - player.up_direction * 3.0)
	_q.collision_mask = _NPC_NAV_COLLISION_MASK
	_q.exclude = [player.get_rid()]
	var _hit: Dictionary = _space.intersect_ray(_q)
	if not _hit.is_empty():
		var _cn = _hit.collider
		_floor_desc = "%s [%s] layer=%s  %.2f m below the NPC" % [_cn.name, _cn.get_class(),
				str(_cn.collision_layer) if "collision_layer" in _cn else "?",
				(player.global_position - _hit.position).dot(player.up_direction)]
	var _off: Vector3 = near_npc - player.global_position
	var _vert: float = _off.dot(player.up_direction)
	var _horiz: float = (_off - player.up_direction * _vert).length()
	print("    standing on: %s" % _floor_desc)
	# Physics-vs-bake probe: what does the PHYSICS world contain along the route where the bake found
	# nothing? Distinguishes "terrain collider not resident" (pin/streaming problem: ray hits NOTHING or
	# only a body far below) from "collider present but not baked" (parse/filter problem: ray hits ground
	# near 0 m yet the navmesh coverage line shows X there).
	var _proot := _npc_nav_world_root()
	if _proot != null and "planet_terrain" in _proot and _proot.planet_terrain != null:
		var _pt = _proot.planet_terrain
		print("    terrain chunks: resident=%d loading=%d queued=%d pinned=%d" % [
				_pt._server_collision_chunks.size(), _pt._server_chunk_tasks.size(),
				_pt._server_chunk_queue.size(), _pt._pinned_chunks.size()])
	var _probe_line := ""
	for i in 9:
		var _pp: Vector3 = player.global_position.lerp(target, float(i) / 8.0)
		var _pq := PhysicsRayQueryParameters3D.create(
				_pp + player.up_direction * 20.0, _pp - player.up_direction * 60.0)
		_pq.collision_mask = _NPC_NAV_COLLISION_MASK
		_pq.exclude = [player.get_rid()]
		var _ph: Dictionary = _space.intersect_ray(_pq)
		if _ph.is_empty():
			_probe_line += "[%d/8: NOTHING] " % i
		else:
			var _pdy: float = (_ph.position - _pp).dot(player.up_direction)
			_probe_line += "[%d/8: %s %+.1f m] " % [i, _ph.collider.name, _pdy]
	print("    physics ground along route (ray 20 m up -> 60 m down): %s" % _probe_line)
	print("    nearest navmesh is %.2f m %s the NPC and %.2f m sideways  (agent_max_climb=0.40) %s" % [
			absf(_vert), "BELOW" if _vert < 0.0 else "ABOVE", _horiz,
			"  <-- NPC is not on its own navmesh" if absf(_vert) > 0.4 else ""])
	print("    path_points=%d  path_ends_%.2f m_from_goal %s" % [path.size(), path_end_gap,
			"  <-- PARTIAL PATH" if path_end_gap > 1.0 else ""])
	# Which region actually owns the mesh under each end? "Both on mesh" means nothing if they are on
	# two DIFFERENT regions — a query across unconnected regions returns exactly this 2-point stub.
	var our_rid: RID = _npc_nav_region
	var own_npc: RID = NavigationServer3D.map_get_closest_point_owner(map, _npc_to_nav(player.global_position))
	var own_goal: RID = NavigationServer3D.map_get_closest_point_owner(map, _npc_to_nav(target))
	print("    mesh owner: NPC=%s  GOAL=%s" % [
			"ours" if own_npc == our_rid else "OTHER REGION", "ours" if own_goal == our_rid else "OTHER REGION"])
	# Sample the straight line NPC->goal. Two DIFFERENT questions, and only the second one matters:
	#   coverage    — is there mesh near this point? (proximity; blind to a wall splitting the mesh)
	#   reachable   — can the NPC actually WALK there? (connectivity; this is what pathing needs)
	# Mesh can be continuous by proximity and still be two islands with a wall between them.
	var _steps := 24
	var _map_line := ""
	var _reach_line := ""
	var _first_block := -1.0
	var _last_ok := 0.0
	for i in _steps + 1:
		var _p: Vector3 = player.global_position.lerp(target, float(i) / float(_steps))
		var _c := _npc_from_nav(NavigationServer3D.map_get_closest_point(map, _npc_to_nav(_p)))
		var _o := NavigationServer3D.map_get_closest_point_owner(map, _npc_to_nav(_p))
		if _c.distance_to(_p) > 1.5:
			_map_line += "X"          # no navmesh here at all
		elif _o == our_rid:
			_map_line += "."          # our baked mesh
		else:
			_map_line += "o"          # a different region's mesh
		var _pth := NavigationServer3D.map_get_path(map, _npc_to_nav(player.global_position), _npc_to_nav(_c), true)
		var _ok: bool = _pth.size() > 0 and _npc_from_nav(_pth[_pth.size() - 1]).distance_to(_c) < 1.0
		_reach_line += "." if _ok else "X"
		if _ok:
			_last_ok = player.global_position.distance_to(_p)
		elif _first_block < 0.0:
			_first_block = player.global_position.distance_to(_p)
	print("    coverage    ('.'=ours 'o'=other 'X'=none)   over %.0f m: %s" % [
			player.global_position.distance_to(target), _map_line])
	print("    REACHABILITY('.'=can walk 'X'=cannot)        over %.0f m: %s" % [
			player.global_position.distance_to(target), _reach_line])
	if _first_block >= 0.0:
		print("    NPC can walk out to %.1f m; first UNREACHABLE point is %.1f m away  <-- the barrier is there" % [
				_last_ok, _first_block])
	# Navmesh height along the route, relative to the NPC (measured along up). A STEP larger than
	# agent_max_climb splits the mesh into islands you cannot walk between — mesh exists on both sides, so
	# coverage looks perfect while reachability dies. This is the shape of a doorway sill / a building
	# floor sitting proud of the terrain outside it.
	var _prof := ""
	var _prev := 0.0
	var _max_step := 0.0
	var _step_at := 0.0
	for i in _steps + 1:
		var _p: Vector3 = player.global_position.lerp(target, float(i) / float(_steps))
		var _c := _npc_from_nav(NavigationServer3D.map_get_closest_point(map, _npc_to_nav(_p)))
		var _dy: float = (_c - player.global_position).dot(player.up_direction)
		if i > 0 and absf(_dy - _prev) > _max_step:
			_max_step = absf(_dy - _prev)
			_step_at = player.global_position.distance_to(_p)
		_prev = _dy
		_prof += "%+.1f " % _dy
	print("    navmesh height along route (m, rel. NPC): %s" % _prof)
	# Where does the baked mesh actually live, and how big is the island the NPC is standing on? The
	# route samples only look along one line; a ring shows the island's true size in every direction.
	if _npc_nav_mesh != null:
		var _vs := _npc_nav_mesh.get_vertices()
		if _vs.size() > 0:
			var _vb := AABB(_vs[0], Vector3.ZERO)
			for _v in _vs:
				_vb = _vb.expand(_v)
			print("    navmesh lives at (nav space) pos=%s size=%s  [must be near 0,0,0 - NPC is at %s]" % [
					_vb.position.round(), _vb.size.round(), _npc_to_nav(player.global_position).round()])
	var _ring := ""
	var _island := 0.0
	for _r in [1.0, 2.0, 4.0, 8.0, 16.0, 32.0]:
		var _hits := 0
		for _a in 8:
			var _dir: Vector3 = Vector3.RIGHT.rotated(Vector3.UP, TAU * float(_a) / 8.0)
			var _wp: Vector3 = player.global_position + (_npc_nav_frame.global_transform.basis * _dir) * _r
			var _cc := _npc_from_nav(NavigationServer3D.map_get_closest_point(map, _npc_to_nav(_wp)))
			var _pp := NavigationServer3D.map_get_path(map, _npc_to_nav(player.global_position), _npc_to_nav(_cc), true)
			if _pp.size() > 0 and _npc_from_nav(_pp[_pp.size() - 1]).distance_to(_cc) < 1.0:
				_hits += 1
		_ring += "%dm:%d/8  " % [int(_r), _hits]
		if _hits > 0:
			_island = _r
	print("    reachable ring around NPC: %s  -> island reaches ~%.0f m" % [_ring, _island])
	print("    biggest step %.2f m at %.1f m from the NPC (agent_max_climb=%.2f) %s" % [
			_max_step, _step_at, 0.4,
			"  <-- OVER max climb: this is what splits the mesh" if _max_step > 0.4 else ""])
	print("    up_direction=%s  angle_vs_BAKE_FRAME_up=%.1f deg %s" % [player.up_direction, up_err,
			"  <-- bake frame is not aligned to the ground; it rasterizes as a slope" if up_err > 30.0 else ""])

## The NPC destination in GLOBAL space. player.npc_go_to_position is stored in the NPC PARENT's frame
## (so a destination stays glued to the planet it was given on, instead of drifting when the planet moves
## or the origin rebases), but NavigationAgent3D.target_position and every global_position comparison are
## world-space — so convert on each read rather than caching a global that goes stale.
func _npc_target_global() -> Vector3:
	var _parent = player.get_parent()
	if _parent is Node3D:
		return (_parent as Node3D).global_transform * player.npc_go_to_position
	return player.npc_go_to_position

## Ground-plane distance from the body to the goal. Height is projected out (gravity owns the vertical
## axis, and the goal may sit a bit above/below the exact ground the NPC settles on) so it can't gate
## arrival. Caller must have already checked player.npc_go_to_position != null.
func _npc_ground_dist_to_goal() -> float:
	var _d: Vector3 = _npc_target_global() - player.global_position
	_d -= player.up_direction * _d.dot(player.up_direction)
	return _d.length()

## The NPC reached its destination: clear the goal (so _npc_physics_process stops re-baking / re-pathing
## and idles) and tell the brain, ONCE. Clearing the goal is what makes this edge-triggered — the arrival
## branch can't be reached again until a new npc_go_to_position arrives.
##
## npc_arrived goes out as a MERGED property, i.e. a sticky state, not a one-shot event: it stays true on
## the brain's side until the brain acks it with the "npc_arrived_ack" action, which resets it to false
## (see server_action_received). Without that ack the next journey would begin with a stale true.
func _npc_notify_arrived() -> void:
	player.npc_go_to_position = null
	# Forget the goal we were tracking rather than comparing against it: the brain may well send the very
	# same position again (re-dispatched to the same workplace), and an unchanged value would not look
	# like a new goal — the next journey would then inherit this one's detour count and watchdog state.
	_npc_goal_seen = null
	player.server_send_properties_to_client({"npc_arrived": true})

# Constant angular speed of the stand-and-face turn (rad/s): half a turn per second, a calm human
# pivot. The walk turn (_npc_face) keeps its own exponential smoothing.
const _NPC_FACE_TURN_SPEED: float = PI

## Pivot the standing NPC toward player.npc_face_position at constant speed, rotating around its own
## up axis so the body stays upright in any gravity frame (a planet included). Cleared once aligned.
## Runs from the no-destination branch of _npc_physics_process; the emit_move right after it
## replicates each step, so clients see the same smooth turn.
func _npc_update_face_target(delta: float) -> void:
	if player.npc_face_position == null:
		return
	var _parent = player.get_parent()
	var target: Vector3 = (_parent as Node3D).global_transform * player.npc_face_position \
			if _parent is Node3D else player.npc_face_position
	var up: Vector3 = player.up_direction
	# Both the goal direction and the current forward, projected on the ground plane: facing is a
	# yaw-only affair, the head pitch handles the vertical component.
	var to: Vector3 = target - player.global_position
	to = to - up * to.dot(up)
	var fwd: Vector3 = -player.global_basis.z
	fwd = fwd - up * fwd.dot(up)
	if to.length_squared() < 0.0001 or fwd.length_squared() < 0.0001:
		# Standing on (or gimbal-locked against) the target: nothing sane to face.
		player.npc_face_position = null
		return
	to = to.normalized()
	fwd = fwd.normalized()
	var ang: float = fwd.signed_angle_to(to, up)
	var max_step: float = _NPC_FACE_TURN_SPEED * delta
	if absf(ang) <= max_step:
		player.global_basis = Basis.looking_at(to, up).orthonormalized()
		player.npc_face_position = null
		return
	player.global_basis = Basis.looking_at(fwd.rotated(up, clampf(ang, -max_step, max_step)), up) \
			.orthonormalized()

## Turn the NPC's body toward its walk direction (a real player's rotation comes from client input,
## which an NPC has none of). -Z faces the direction — the same convention the input path uses
## (forward input is Vector3(0,0,-1) through global_basis) — with the body kept upright along
## up_direction, so it works on a planet where "up" is radial. Smoothed with an exponential factor so
## corners turn naturally instead of snapping; frame-rate independent.
func _npc_face(direction: Vector3, delta: float) -> void:
	if direction.length_squared() < 0.0001:
		return
	var _target := Basis.looking_at(direction, player.up_direction)
	var _t: float = 1.0 - exp(-_NPC_TURN_SHARPNESS * delta)
	player.global_basis = player.global_basis.orthonormalized().slerp(_target, _t)

## Forget everything the watchdog has learned. Called when the NPC is handed a NEW goal: the old
## recovery state describes a journey that is over, and a detour picked for it would drag the NPC the
## wrong way.
func _npc_reset_recovery() -> void:
	_npc_progress_ref = player.global_position
	_npc_progress_timer = 0.0
	_npc_recover_step = 0
	_npc_detour = null
	_npc_detour_timer = 0.0
	_npc_detour_count = 0

## Progress watchdog. An NPC that covers less than _NPC_PROGRESS_MIN of ground in _NPC_PROGRESS_WINDOW
## is not getting anywhere — wedged on geometry, orbiting a waypoint, or parked at the closest reachable
## point to a goal it cannot actually reach — so climb one rung of the recovery ladder.
##
## Measured over a WINDOW, not per frame. The previous test (moved less than 5 cm since the last frame
## that moved 5 cm) only ever caught a body at a dead stop: an NPC scraping along a wall at 0.3 m/s
## reset the timer every single frame and stayed stuck forever.
func _npc_update_stuck(delta: float) -> void:
	_npc_progress_timer += delta
	if _npc_progress_timer < _NPC_PROGRESS_WINDOW:
		return
	var _moved: float = player.global_position.distance_to(_npc_progress_ref)
	_npc_progress_timer = 0.0
	_npc_progress_ref = player.global_position
	if _moved >= _NPC_PROGRESS_MIN:
		_npc_recover_step = 0  # walking normally again: the ladder starts from the bottom next time
		return
	_npc_recover_step += 1
	_npc_try_unstick()

## One rung of recovery for an NPC that has stopped making headway, escalating with _npc_recover_step so
## the cheap and safe fixes are tried before the disruptive ones:
##   1. re-bake and re-path — a stale mesh, a goal that moved, or a bake that was still running;
##   2. snap back onto the navmesh — a body wedged just off its own mesh (tightly gated, see below);
##   3+ detour — abandon the direct route and walk to a reachable intermediate point first. This is the
##      rung that gets an NPC out of a dead end, or around an obstacle its direct route keeps hugging,
##      at the cost of a longer walk.
## Rungs 3+ repeat with a rotating sample phase, so successive attempts explore different sides instead
## of re-picking the direction that just failed.
func _npc_try_unstick() -> void:
	if _npc_recover_step == 1:
		_npc_nav_bake_center = null  # make _ensure_npc_nav_region bake fresh coverage next tick
		_npc_repath()
		return
	if _npc_recover_step == 2:
		_npc_snap_onto_mesh()
		_npc_repath()
		return
	if not _npc_pick_detour():
		# Nothing reachable to detour through — the NPC is walled in, or the mesh around it is stale.
		# Fall back to the cheap rungs rather than standing still.
		_npc_nav_bake_center = null
		_npc_snap_onto_mesh()
	_npc_repath()

## Pick a reachable intermediate point to route through, so a blocked NPC takes a different way round
## even if it is longer. Stores it in _npc_detour and returns true on success.
##
## Candidates sit on a ring of _NPC_DETOUR_RADIUS around the NPC. Being ON the mesh is not enough — the
## point must be on OUR side of the walls, so each one is probed with a real path query and kept only if
## the route actually ENDS there (an unreachable target yields a stub that stops against the geometry in
## between). Among the survivors we take the one closest to the real goal, which keeps the detour
## purposeful instead of sending the NPC wandering.
func _npc_pick_detour() -> bool:
	var _map: RID = _npc_map()
	if _map == RID() or NavigationServer3D.map_get_iteration_id(_map) == 0:
		return false
	var _here_nav: Vector3 = _npc_to_nav(player.global_position)
	var _goal: Vector3 = _npc_target_global()
	# Rotate the ring between attempts so a repeat does not re-pick the direction that just failed.
	var _phase: float = float(_npc_recover_step) * 0.7
	var _best = null
	var _best_score: float = INF
	for i in range(_NPC_DETOUR_SAMPLES):
		var _ang: float = TAU * float(i) / float(_NPC_DETOUR_SAMPLES) + _phase
		# Nav space has +Y up by construction (see _npc_surface_frame), so the ring lies in XZ.
		var _cand: Vector3 = _here_nav + Vector3(cos(_ang), 0.0, sin(_ang)) * _NPC_DETOUR_RADIUS
		var _on_mesh: Vector3 = NavigationServer3D.map_get_closest_point(_map, _cand)
		var _probe := NavigationServer3D.map_get_path(_map, _here_nav, _on_mesh, true)
		if _probe.size() < 2 or _probe[_probe.size() - 1].distance_to(_on_mesh) > 1.0:
			continue  # cannot actually get there from here
		var _world: Vector3 = _npc_from_nav(_on_mesh)
		if player.global_position.distance_to(_world) < _NPC_DETOUR_RADIUS * 0.5:
			continue  # snapped back to roughly where we already stand: not a different route
		var _score: float = _world.distance_to(_goal)
		if _score < _best_score:
			_best_score = _score
			_best = _world
	if _best == null:
		return false
	_npc_detour = _best
	_npc_detour_timer = _NPC_DETOUR_TIMEOUT
	_npc_detour_count += 1
	if _npc_detour_count == 6:
		# Loud once per goal, not per detour. Six different ways round and still no arrival: the goal is
		# very likely unreachable (sealed room, wrong side of a wall) rather than merely awkward. The NPC
		# keeps trying regardless — it just does so on the record, so the schedule stalling upstream has
		# a visible cause.
		push_warning("NPC %s has taken %d detours without reaching goal %s; it may be unreachable"
				% [player.name, _npc_detour_count, player.npc_go_to_position])
	return true

## Retire the active detour once it has been reached or has run out of time, so the NPC goes back to
## aiming at its real goal.
func _npc_update_detour(delta: float) -> void:
	if _npc_detour == null:
		return
	_npc_detour_timer -= delta
	var _d: Vector3 = (_npc_detour as Vector3) - player.global_position
	_d -= player.up_direction * _d.dot(player.up_direction)
	if _npc_detour_timer <= 0.0 or _d.length() <= _NPC_ARRIVED_DIST:
		_npc_detour = null
		_npc_repath()

## Where the ROUTE currently aims: the active detour if there is one, else the real goal. Arrival keeps
## being judged against the real goal (_npc_ground_dist_to_goal), so a detour can never be mistaken for
## the destination and acked to the brain.
func _npc_route_target_global() -> Vector3:
	if _npc_detour != null:
		return _npc_detour
	return _npc_target_global()

## Nudge a wedged NPC back onto the navmesh. This ASSIGNS global_position, i.e. it moves the body with no
## collision test whatsoever — the one and only way an NPC can end up on the far side of a solid wall. So
## every snap is gated: an unchecked one teleports the NPC THROUGH the hab it is leaning on, which both
## looks like "the NPC walked through the wall" and hides the pathing bug that wedged it in the first
## place. When in doubt, leave it stuck — a visibly stuck NPC is a bug report; a tunnelling one is a
## mystery.
func _npc_snap_onto_mesh() -> void:
	var _nav_map: RID = _npc_map()
	# A query against a map that has not synced yet (or holds no region) does NOT fail loudly — it
	# quietly returns Vector3.ZERO. Snapping to that teleports the NPC to the world origin.
	if NavigationServer3D.map_get_iteration_id(_nav_map) == 0:
		return
	# Bias the search below the NPC (along -up) so we land on ground mesh rather than a roof directly
	# overhead that is also horizontally walkable.
	var _ground_search: Vector3 = player.global_position - player.up_direction * 50.0
	var _nearest_nav := NavigationServer3D.map_get_closest_point(_nav_map, _npc_to_nav(_ground_search))
	if _nearest_nav == Vector3.ZERO:
		return  # query failed; see above
	var _nearest := _npc_from_nav(_nearest_nav)
	var _gap: float = player.global_position.distance_to(_nearest)
	# Only accept mesh we are essentially standing on already. A far snap means the NPC is pressed
	# against geometry its path wrongly crosses, and the nearest mesh is THROUGH that geometry.
	if _gap > 0.3 and _gap <= _NPC_STUCK_SNAP_MAX:
		player.global_position = _nearest + player.up_direction * 0.05
	elif _gap > _NPC_STUCK_SNAP_MAX:
		push_warning("NPC %s wedged %.1f m off the navmesh; refusing to snap (it would tunnel through geometry)"
				% [player.name, _gap])

## Replicate the NPC's authoritative pose to clients (same emitter the input path uses, so the
## frame it declares is derived from the tree in one place — see Player.emit_move).
func _npc_emit_move() -> void:
	player.emit_move()
## Bake a bounded navigation region around the NPC so its agent has ground to path on, creating it on
## first need and re-baking ahead of the NPC once it travels past _NPC_NAV_REBAKE_DIST of the last bake
## center. Baking is async on a worker thread; until it finishes the agent simply has no path.
##
## The bake reads the REAL physics geometry of the world: every static collider under the PLANET
## (terrain chunk bodies, the city, building walls and floors, props) whose layer is in
## _NPC_NAV_COLLISION_MASK — see _npc_nav_world_root for why the planet and not the NPC's own parent.
## We drive the parse ourselves instead of NavigationRegion3D.bake_navigation_mesh() because the latter
## parses from the region node, which would only ever see the region's own (empty) children.
##
## Two things are deliberately decoupled here, which GROUPS_WITH_CHILDREN is what makes possible (it
## walks the group but emits geometry in the parse root's frame):
##   • WHAT is parsed — the whole planet, via _NPC_NAV_SOURCE_GROUP.
##   • WHICH FRAME it is baked in — _npc_nav_frame, aligned to the ground under the NPC, because Recast
##     hard-codes +Y as up in whatever frame it bakes in.
func _ensure_npc_nav_region() -> void:
	if _npc_nav_baking:
		return
	var _root: Node3D = _npc_nav_world_root()
	if _root == null:
		return
	if _npc_nav_frame != null and _npc_nav_frame.get_parent() != _root:
		_npc_nav_frame.get_parent().remove_child(_npc_nav_frame)  # NPC changed world (planet)
		_root.add_child(_npc_nav_frame)
		_root.add_to_group(_NPC_NAV_SOURCE_GROUP)
		_npc_nav_bake_center = null  # force a re-bake in the new world
	var _pos: Vector3 = player.global_position
	var _goal: Vector3 = _npc_target_global()
	# Re-bake when the NPC has travelled, AND when the goal itself moves — the box is built around both,
	# so a new goal invalidates it just as much as a new position does.
	if _npc_nav_region != RID() and _npc_nav_bake_center != null and _npc_nav_bake_goal != null \
			and _pos.distance_to(_npc_nav_bake_center) < _NPC_NAV_REBAKE_DIST \
			and _goal.distance_to(_npc_nav_bake_goal) < _NPC_NAV_REBAKE_DIST:
		return  # still well inside the current baked area
	# A (re)bake is due — but only one NPC may run the synchronous world parse per physics frame.
	# Waiting a tick is harmless here: the NPC keeps walking its current path meanwhile.
	if Engine.get_physics_frames() == _npc_nav_parse_frame:
		return
	_npc_nav_parse_frame = Engine.get_physics_frames()
	if _npc_nav_frame == null:
		_npc_nav_frame = Node3D.new()
		_npc_nav_frame.name = "NpcNavFrame"
		_root.add_child(_npc_nav_frame)
		# Group the NPC's own parent: "every collider in the world this NPC lives in", picked up
		# automatically with no scene authoring. Idempotent, so every NPC can do this.
		_root.add_to_group(_NPC_NAV_SOURCE_GROUP)
	if _npc_nav_region == RID():
		var _mesh := NavigationMesh.new()
		# These four together decide whether DOORWAYS bake open, and standard apartment doors are 1.0 m
		# wide x 2.0 m tall (apartment_ares_worker_001 trimesh), so the margins are thin:
		#   width  — Recast erodes ceil(agent_radius / cell_size) voxels of walkable space off EACH side
		#            of a door. The old 0.4 / 0.25 pair eroded 0.5 m per side: the whole 1.0 m door, so
		#            interiors baked as sealed islands and NPCs walked into the door frame and stopped.
		#            0.3 / 0.1 erodes 0.3 m per side, leaving a 0.4 m = 4-cell strip.
		#   phase  — the strip must survive ANY grid alignment. Apartment units tile every 3.16 m, a
		#            non-integer number of voxels, so each unit's door sits at a different sub-voxel
		#            phase. At 0.3/0.125 the strip was ONE marginal voxel: in a real spawn building,
		#            units 0-0-0 and 0-2-0 baked open while 0-1-0 sealed (measured). 4 cells is
		#            phase-proof.
		#   height — the mesh floats ~2*cell_height above the floor and that headroom is taken off every
		#            opening: at cell_height 0.25 a door must be 2.3 m tall to pass, at 0.1 only 1.9 m.
		# agent_radius 0.3 still covers the real capsule (0.265 m) — do NOT shrink the radius below it to
		# widen doors; shrink cell_size instead. The private map is configured from these same values
		# below, so map and mesh always rasterize on the same grid.
		_mesh.cell_size = 0.1
		_mesh.cell_height = 0.1
		_mesh.agent_radius = 0.3
		_mesh.agent_height = 1.8
		_mesh.agent_max_climb = 0.4
		_mesh.agent_max_slope = 45.0
		# Static colliders only, never MESH_INSTANCES/BOTH: we want exactly what the NPC body hits, not
		# decorative meshes it can walk through. CSG buildings ARE covered — a use_collision CSG root is
		# parsed like any other static collider (verified: it contributes its faces).
		_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
		_mesh.geometry_collision_mask = _NPC_NAV_COLLISION_MASK
		# Traversal from the group (the whole world under the NPC's parent), coordinates from the parse
		# root (the surface frame). ROOT_NODE_CHILDREN can't do this: it would tie both to one node.
		_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
		_mesh.geometry_source_group_name = _NPC_NAV_SOURCE_GROUP
		_npc_nav_mesh = _mesh
		# A private map holding only this NPC's bake. On the shared world map our region would also sit
		# alongside the designer-authored ones (the city / depot navmesh), which overlap ours and can win
		# the destination-polygon-by-proximity lookup for a region we have no connection to.
		_npc_nav_map = NavigationServer3D.map_create()
		NavigationServer3D.map_set_cell_size(_npc_nav_map, _mesh.cell_size)
		NavigationServer3D.map_set_cell_height(_npc_nav_map, _mesh.cell_height)
		NavigationServer3D.map_set_active(_npc_nav_map, true)
		# IDENTITY, and driven through the server rather than a node: the mesh is baked in
		# _npc_nav_frame's space and must STAY near the origin. Parent it to anything out at the planet's
		# coordinates and the server's 21-bit PointKeys overflow, no polygons connect, and the NPC cannot
		# walk across flat ground. See _npc_to_nav.
		_npc_nav_region = NavigationServer3D.region_create()
		NavigationServer3D.region_set_map(_npc_nav_region, _npc_nav_map)
		NavigationServer3D.region_set_transform(_npc_nav_region, Transform3D.IDENTITY)
		NavigationServer3D.region_set_enabled(_npc_nav_region, true)

	# Re-anchor the bake frame on the NPC, +Y along its local up. Only ever moved here, immediately before
	# a bake: nav space is defined by this frame, so moving it without re-baking would silently shift
	# every existing path point off the ground it was baked for.
	_npc_nav_frame.transform = _npc_surface_frame(_root)
	# The box must hold the NPC *and* its goal. Sizing it around the NPC alone deadlocks: the goal falls
	# outside, so it lands on some OTHER region (or none), a query across two unconnected regions returns
	# a 2-point stub, the NPC never moves — and because the box follows the NPC, it never grows to reach
	# the goal either. That is the "NPC always walks into the wall": measured goal 56 m out vs a ±30 m box.
	var _half := Vector3.ONE * _NPC_NAV_HALF_EXTENT
	var _box := AABB(-_half, _half * 2.0)  # the NPC is at the frame's origin by construction
	var _goal_f: Vector3 = _npc_nav_frame.global_transform.affine_inverse() * _goal
	if _goal_f.length() > _NPC_NAV_MAX_EXTENT:
		# Too far to voxelize in one bake: aim at the box edge, walk, re-bake from there.
		_goal_f = _goal_f.normalized() * _NPC_NAV_MAX_EXTENT
	_box = _box.expand(_goal_f).grow(_NPC_NAV_GOAL_MARGIN)
	# Flatten the box vertically around the two ground-level endpoints — it spans up to ~120 m
	# horizontally now, and voxelizing that much sky at cell_height would cost far more than it buys.
	_box.position.y = minf(0.0, _goal_f.y) - _NPC_NAV_VERTICAL
	_box.size.y = (maxf(0.0, _goal_f.y) + _NPC_NAV_VERTICAL) - _box.position.y
	# Bake into a COPY and publish it when done, so the live mesh is never half-written.
	var _mesh_next: NavigationMesh = _npc_nav_mesh.duplicate()
	_mesh_next.filter_baking_aabb = _box
	_npc_nav_bake_center = _pos
	_npc_nav_bake_goal = _goal
	_npc_nav_baking = true
	var _src := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(_mesh_next, _src, _npc_nav_frame)
	NavigationServer3D.bake_from_source_geometry_data_async(
			_mesh_next, _src, _on_npc_nav_bake_finished.bind(_mesh_next))

## The map every NPC nav query must go through: this NPC's private one once it exists. Falls back to the
## world map before the first bake.
func _npc_map() -> RID:
	if _npc_nav_map != RID():
		return _npc_nav_map
	return player.get_world_3d().navigation_map

## World point → NAV SPACE, and back. EVERY navigation query and result must go through these.
##
## The navigation server cannot work at this game's coordinates. It connects polygons by quantizing each
## vertex into a PointKey — floor(pos / cell_size) packed into a 21-bit signed bitfield — which saturates
## around ±262 km at cell_size 0.25. Our planet sits ~1.26e10 out, so every key overflows, no two polygons
## are ever found to share an edge, and the mesh degenerates into 557 disconnected islands: flat ground
## the NPC cannot walk two metres across. Measured on identical geometry: reachable 56.4 m at the origin,
## 16.4 m at 1.26e10, and 0 m with the real terrain's polygon count.
##
## So the mesh is baked in _npc_nav_frame's space (±60 m of the NPC), the region is registered at IDENTITY
## so it LIVES near the origin where the keys still resolve, and we convert on the way in and out.
func _npc_to_nav(world_point: Vector3) -> Vector3:
	if _npc_nav_frame == null:
		return world_point
	return _npc_nav_frame.global_transform.affine_inverse() * world_point

func _npc_from_nav(nav_point: Vector3) -> Vector3:
	if _npc_nav_frame == null:
		return nav_point
	return _npc_nav_frame.global_transform * nav_point

## Ask the server for a fresh route to the goal, in nav space. Cheap enough to re-issue on a timer.
func _npc_repath() -> void:
	_npc_path = PackedVector3Array()
	_npc_path_idx = 0
	if _npc_nav_map == RID() or _npc_nav_frame == null or player.npc_go_to_position == null:
		return
	if NavigationServer3D.map_get_iteration_id(_npc_nav_map) == 0:
		return  # map not synced yet; queries would silently return nothing
	_npc_path = NavigationServer3D.map_get_path(_npc_nav_map,
			_npc_to_nav(player.global_position), _npc_to_nav(_npc_route_target_global()), true)
	_npc_widen_path_corners()

## Push the path's interior corners off the geometry they hug.
##
## map_get_path funnels the corridor, so every interior corner sits exactly ON a navmesh vertex — and
## the mesh boundary is agent_radius (0.30 m) from the wall, of which the capsule (0.265 m) eats all but
## ~3 cm. Walking that line, the slightest turn overshoot scrapes the wall, which is the "NPC wedged on
## the corner of a wall" bug. Each corner is therefore nudged along the OUTWARD bisector of its two legs
## (`in - out` points away from the vertex the path wraps around) by _NPC_CORNER_CLEARANCE.
##
## The nudge is validated, never blind: a candidate that leaves the mesh is halved, then quartered, then
## dropped. That is what keeps narrow openings working — inside a 0.9 m door the corridor is only 0.3 m
## wide once eroded, so there is nowhere to push and the corner simply stays where the funnel put it.
## Do NOT "fix" corner scraping by raising agent_radius instead: 0.3 is already the widest radius a
## 0.9 m door can pass (0.9 - 2*0.3 = 0.3 m of corridor left, i.e. 3 cells at cell_size 0.1).
func _npc_widen_path_corners() -> void:
	if _npc_path.size() < 3:
		return
	# Every bisector is measured on the ORIGINAL path, never on the partly-widened one. Recast chamfers a
	# convex corner into two vertices ~0.2 m apart, so with in-place reads the second corner takes its
	# incoming leg from the already-moved first one — the bisector then points along the wall instead of
	# away from it, and the push lands INSIDE the geometry (measured: straight into the wall it was
	# supposed to clear).
	var _src := PackedVector3Array(_npc_path)
	for i in range(1, _src.size() - 1):
		var _cur: Vector3 = _src[i]
		# Nav space has +Y up by construction (see _npc_surface_frame), so the ground plane is XZ and no
		# projection along up_direction is needed here.
		var _in: Vector3 = _cur - _src[i - 1]
		var _out: Vector3 = _src[i + 1] - _cur
		_in.y = 0.0
		_out.y = 0.0
		if _in.length_squared() < 0.0001 or _out.length_squared() < 0.0001:
			continue
		var _push: Vector3 = _in.normalized() - _out.normalized()
		if _push.length_squared() < 0.0001:
			continue  # straight through: not a corner, nothing to widen
		_push = _push.normalized()
		for _f in [1.0, 0.5, 0.25]:
			var _cand: Vector3 = _cur + _push * (_NPC_CORNER_CLEARANCE * _f)
			var _snap: Vector3 = NavigationServer3D.map_get_closest_point(_npc_nav_map, _cand)
			if _snap.distance_to(_cand) <= _NPC_CORNER_ON_MESH_EPS:
				_npc_path[i] = _snap  # the snapped point, so the waypoint is guaranteed ON the mesh
				break

## Next point to steer at, in WORLD space, or null when there is no usable path left. Consumes waypoints
## we have already reached.
##
## A waypoint is only dropped once we are standing on it (_NPC_WAYPOINT_REACHED) or have walked PAST it
## — past the plane through it, perpendicular to the leg that led there. Dropping it any earlier means
## steering at the waypoint that follows the corner from before the corner: a shortcut straight into the
## wall, with only ~3 cm of clearance to absorb it. See _NPC_WAYPOINT_REACHED.
func _npc_next_path_point():
	while _npc_path_idx < _npc_path.size():
		var _p: Vector3 = _npc_from_nav(_npc_path[_npc_path_idx])
		# Compare in the ground plane: gravity owns the vertical axis, so height must not gate arrival.
		var _d: Vector3 = _p - player.global_position
		_d -= player.up_direction * _d.dot(player.up_direction)
		var _dist: float = _d.length()
		if _dist <= _NPC_WAYPOINT_REACHED:
			_npc_path_idx += 1
			continue
		# Passed it? Needs a leg to measure along (path[0] is our own position, so it has none) and only
		# counts from nearby — see _NPC_PASSED_MAX_DIST.
		if _npc_path_idx > 0 and _dist < _NPC_PASSED_MAX_DIST:
			var _leg: Vector3 = _p - _npc_from_nav(_npc_path[_npc_path_idx - 1])
			_leg -= player.up_direction * _leg.dot(player.up_direction)
			if _leg.length_squared() > 0.0001 and _d.dot(_leg.normalized()) < 0.0:
				_npc_path_idx += 1
				continue
		return _p
	return null

## Release the private navigation map with the NPC (it is a raw server RID: nothing else frees it).
func _exit_tree() -> void:
	if _npc_nav_region != RID():
		NavigationServer3D.free_rid(_npc_nav_region)
		_npc_nav_region = RID()
	if _npc_nav_map != RID():
		NavigationServer3D.free_rid(_npc_nav_map)
		_npc_nav_map = RID()

## The node the bake TRAVERSES for source geometry: the whole world the NPC can walk around in.
##
## Emphatically NOT player.get_parent(). A player is parented to the APARTMENT it spawned in (the spawn
## event sends parent_id == spawn_appartment_id, e.g. "tarsis_4-1002"), so grouping the parent parses
## that one apartment's collider and nothing else — measured: 38 polys of apartment floor, identical
## under every bake setting, leaving the NPC able to walk only as far as its own wall. The planet is the
## node that actually holds the terrain chunks AND the city (the city spawns with the planet as parent).
func _npc_nav_world_root() -> Node3D:
	# <planet>/<body>/PlanetGravity — the same hop Player itself uses to identify its planet.
	var _grav: Node3D = player.get_current_gravity_parent()
	if _grav != null and _grav.get_parent() != null:
		var _planet: Node = _grav.get_parent().get_parent()
		if _planet is Node3D and "planet_terrain" in _planet:
			return _planet as Node3D
	# In space, or no gravity area registered yet: fall back to the whole scene. Broader parse than we
	# want, but correct — better than silently baking one room.
	return get_tree().get_current_scene() as Node3D

## The frame the navmesh is baked in, expressed in the NPC parent's space: origin on the NPC, +Y along
## its up direction (radial on a planet). Recast ALWAYS treats +Y as up in whatever frame it bakes in.
## The planet's +Y is its axis, so away from the poles it diverges from the ground normal under the NPC
## and flat ground would rasterize as a slope past agent_max_slope. It also defines NAV SPACE: the origin
## rides the NPC, which is what keeps the baked mesh near (0,0,0) — see _npc_to_nav.
func _npc_surface_frame(root: Node3D) -> Transform3D:
	var _up: Vector3 = (root.global_transform.basis.inverse() * player.up_direction).normalized()
	if not _up.is_normalized():
		_up = Vector3.UP  # no gravity frame yet
	# Any two axes perpendicular to up will do — the navmesh only cares which way is up.
	var _fwd: Vector3 = Vector3.FORWARD
	if absf(_up.dot(_fwd)) > 0.9:
		_fwd = Vector3.RIGHT  # degenerate: up is (anti)parallel to the reference axis
	var _x: Vector3 = _fwd.cross(_up).normalized()
	var _z: Vector3 = _x.cross(_up).normalized()
	return Transform3D(Basis(_x, _up, _z), root.global_transform.affine_inverse() * player.global_position)

## Bake worker finished: publish the fresh mesh to the NavigationServer, clear the flag and re-issue the
## target so the agent paths on it.
func _on_npc_nav_bake_finished(baked: NavigationMesh) -> void:
	_npc_nav_baking = false
	if _npc_nav_region == RID() or not is_instance_valid(player):
		return
	_npc_nav_mesh = baked
	NavigationServer3D.region_set_navigation_mesh(_npc_nav_region, baked)
	# The path we were following was baked against the previous mesh; re-issue it against the new one.
	_npc_repath()

## Primitive: true if a MASK_OBSTACLE ray from the eye to `target` (a world point) is cut by a solid
## before reaching it. `exceptions` are solids to ignore besides ourselves. Used for look-at boxes that
## sit in open air (door handles): the box on the near side is clear, the one behind the body is not.
func _line_of_sight_blocked(target: Vector3, exceptions: Array) -> bool:
	_ensure_los_ray()
	# top_level → target_position is a world-space delta (no parent transform to fight).
	_los_ray.global_position = player.interact_ray.global_position
	_los_ray.target_position = target - _los_ray.global_position
	_los_ray.clear_exceptions()
	_los_ray.add_exception(player)
	for node in exceptions:
		if node is CollisionObject3D:
			_los_ray.add_exception(node)
	_los_ray.force_raycast_update()
	if not _los_ray.is_colliding():
		return false
	# Float32 precision at astronomic world coordinates (the same limit behind the Jolt "dancing" bug)
	# makes the PHYSICS raycast origin imprecise by tens of metres this far out, so it can report a body
	# well off the true eye->box segment as a hit and lock a door that is actually clear. Validate in
	# DOUBLE precision: a real obstruction sits BETWEEN the eye and the door box, so ignore any collider
	# whose accurate position is farther from the eye than the box itself (+ a small size margin).
	var c: Object = _los_ray.get_collider()
	if c is Node3D:
		var box_dist: float = _los_ray.global_position.distance_to(target)
		var hit_dist: float = _los_ray.global_position.distance_to(_los_hit_world_pos(c))
		if hit_dist > box_dist + 2.0:
			return false
	return true

## Server-authoritative "can I actually SEE it?" gate, shared by EVERY look-at interaction (carry AND
## door handles): nothing solid may stand in front of the target. MUST run on the server — the client
## has no collisions, so its answer would always be "clear" and be trivially cheatable.
func _can_see(target: Node) -> bool:
	if not (target is Node3D):
		return false
	# Door handle: pick the box for the side the player is on — seated in this vehicle → indoor box,
	# on foot → outdoor box — then require a clear sightline to it. The vehicle's own collision is a
	# coarse CONVEX hull that encloses the boxes, so we exclude it (it can't self-block); FOREIGN walls
	# still block. Choosing the box by seated-state is what stops opening a door you can't see.
	if target.has_method("side_shape"):
		var veh: Node = target.vehicle() if target.has_method("vehicle") else null
		var inside: bool = veh != null and veh.has_method("is_occupied_by") and veh.is_occupied_by(player)
		var box: Node3D = target.side_shape(inside)
		if box == null:
			return true  # handle without assigned boxes: don't lock the door
		# Exclude the vehicle's coarse convex self-hull (it encloses the boxes, can't self-block); FOREIGN
		# walls still block.
		return not _line_of_sight_blocked(box.global_position, [veh])
	# Otherwise the target IS the solid we look at (a carriable): a solids ray must reach IT first — a
	# wall, a bed side or the bodywork in front is hit instead, so the target is not visible.
	return _first_solid_hit_is(target)

## True if a MASK_OBSTACLE ray from the eye toward `target` hits `target` ITSELF first (nothing solid
## in front of it). We only ignore ourselves; whatever the target rests in/on is NOT excluded, so you
## can't grab an object through the side of the bed it sits in — you must actually see it.
func _first_solid_hit_is(target: Node3D) -> bool:
	_ensure_los_ray()
	_los_ray.global_position = player.interact_ray.global_position
	var to_target: Vector3 = target.global_position - _los_ray.global_position
	# Aim a touch past the centre so a thin/small target is still crossed by the ray.
	_los_ray.target_position = to_target * 1.05
	_los_ray.clear_exceptions()
	_los_ray.add_exception(player)
	_los_ray.force_raycast_update()
	# Float32 precision at astronomic world coordinates makes this physics ray imprecise (same limit as
	# the door LOS / Jolt "dancing" bug): far from the origin it can miss the target or catch a body well
	# off the eye->target segment, so a grab is refused until you are almost inside the prop. The client
	# already aimed at it; validate in DOUBLE precision. A miss, or a hit BEYOND the target, counts as
	# visible; only a solid genuinely CLOSER than the target (a wall / bed side in front) blocks the grab.
	if not _los_ray.is_colliding():
		return true
	var c: Object = _los_ray.get_collider()
	if c == target or (c is Node and (target.is_ancestor_of(c) or (c as Node).is_ancestor_of(target))):
		return true
	if c is Node3D:
		var target_dist: float = _los_ray.global_position.distance_to(target.global_position)
		var hit_dist: float = _los_ray.global_position.distance_to(_los_hit_world_pos(c))
		return hit_dist > target_dist
	return false

## True if a solid wall stands between the eye and the carriable `prop`. Thin wrapper over `_can_see`
## for the carry call sites; tiny ore pieces detect unreliably, so we don't gate them on sight.
func _is_blocked_by_geometry(prop: Node) -> bool:
	if prop is Node3D and "type_name" in prop and prop.type_name == "miningrock":
		return false
	return not _can_see(prop)

## World position of the SPECIFIC collision shape the LOS ray hit — NOT the whole CollisionObject's
## origin. A building is a multi-cell StaticBody: get_collider() returns that body, whose origin sits at
## one corner, far from the wall you actually hit. Comparing THAT distance to the target wrongly reads
## the wall as "beyond" the target and lets you grab/open through it. The hit SHAPE's own transform is
## right at the wall. Node transforms are double precision here; get_collision_point() is not (Jolt
## float32 → km-off at astronomic coords). Falls back to the collider origin if the shape can't resolve.
func _los_hit_world_pos(c: Object) -> Vector3:
	if c is CollisionObject3D:
		var obj := c as CollisionObject3D
		var owner_id: int = obj.shape_find_owner(_los_ray.get_collider_shape())
		if owner_id != -1:
			return (obj.global_transform * obj.shape_owner_get_transform(owner_id)).origin
	if c is Node3D:
		return (c as Node3D).global_position
	return Vector3.ZERO

## Lazily create the body-only line-of-sight ray (a node, so force_raycast_update works in
## _process / input / server alike — direct_space_state is only valid during physics).
func _ensure_los_ray() -> void:
	if _los_ray != null:
		return
	_los_ray = RayCast3D.new()
	_los_ray.enabled = false
	_los_ray.top_level = true  # ignore the player's transform → target_position is a world delta
	_los_ray.collide_with_areas = false
	_los_ray.collide_with_bodies = true
	_los_ray.collision_mask = Globals.MASK_OBSTACLE  # solids only (world|vehicle|prop); player excluded via exceptions
	add_child(_los_ray)

## Put the carried prop DOWN on the placement disc the player is aiming at (see CarryPlacement): into
## a truck bed / a shelf slot when the disc landed on one, else resting on the aimed surface — or, if
## the aim ray hit nothing, in mid-air at the end of the ray, from where it just falls. Placement
## always resolves, so E always releases. Guarded so a repeated/deferred call is a no-op.
func _server_drop_carried_item() -> void:
	if player.hands_item == null:
		return
	var item: RigidBody3D = player.hands_item as RigidBody3D
	# Use the placement the PHYSICS TICK resolved (at most one frame old), never a fresh query: E
	# arrives on the network dispatch, OUTSIDE the physics step, where the space state gives nothing —
	# the ray would silently miss and drop the crate at the end of the ray instead of on its disc.
	# (Same reason the spawn wheel and the stance check queue their raycasts for the step.)
	var place: Dictionary = _place if _place.has("position") else _resolve_placement()
	_place = {}  # consumed: never let it leak into the next pickup
	# Generic: let the object know it is no longer carried (issue #124).
	if player.hands_item.has_method("set_carried"):
		player.hands_item.set_carried(false)
	player.hands_item.remove_collision_exception_with(player)  # clear any stale exception (belt and braces)
	# Restore what the pickup suppressed: the crate is solid again and owns its own physics.
	if player.hands_item.has_meta("pre_carry_layer"):
		player.hands_item.collision_layer = player.hands_item.get_meta("pre_carry_layer")
		player.hands_item.remove_meta("pre_carry_layer")
	if player.hands_item.has_meta("pre_carry_mask"):
		player.hands_item.collision_mask = player.hands_item.get_meta("pre_carry_mask")
		player.hands_item.remove_meta("pre_carry_mask")
	# Seat it on the disc BEFORE handing it to a bed / shelf: both of them read the body's world
	# position to pick their slot, and the mount (on the chest) is not where the player is aiming.
	player.hands_item.global_transform = CarryPlacement.seat(player.hands_item, place, _carry_basis)
	# Drop INTO a bed -> load it onto that truck. We load it if we stand in the bed, OR if we
	# drop it from outside but it lands inside a nearby truck's cargo bay.
	if item != null:
		var bed = _cargo_bed_for_drop(place["position"])
		if bed != null:
			bed.lock_dropped_cargo(item)
			player.hands_item = null
			player.server_send_properties_to_client({"carrying": false})
			return
		# Drop ONTO a shelf slot -> snap the crate into the nearest free slot and freeze it there. The
		# crate stays a normal resting world prop (parented to the world node, not the shelf, which never
		# moves), so its replication rides the ordinary settled-prop path; the shelf only tracks the slot.
		var shelf = place["shelf"] if place["shelf"] != null else _shelf_for_drop(place["position"])
		if shelf != null:
			var shelf_parent = player.get_parent()
			item.server_parent_change(shelf_parent)  # out of the player, into the world
			shelf.store_at_nearest_slot(item, str(shelf_parent.uuid) if "uuid" in shelf_parent else "")
			player.hands_item = null
			player.server_send_properties_to_client({"carrying": false})
			return
	var drop_parent = player.get_parent()
	player.hands_item.server_parent_change(drop_parent)  # reparent() keeps the world pose we just seated
	player.hands_item.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	player.hands_item.freeze = false
	player.hands_item.can_sleep = true
	# Robust to the scene layout: a parent without a uuid (grouping/test-zone node) = "".
	player.hands_item.send_properties_to_client(str(drop_parent.uuid) if "uuid" in drop_parent else "")
	player.hands_item = null
	# Stop carrying on all clients (perforator comes back) (issue #124).
	player.server_send_properties_to_client({"carrying": false})

## Spin the mounted crate by `rot` (BODY-local). The crate is pinned to its mount every tick, so the
## rotation accumulates in _carry_basis instead of the body's transform — and carries over to the
## placed crate's spin about the surface normal when it is put down.
func _rotate_held(rot: Basis) -> void:
	if not is_instance_valid(player.hands_item):
		return
	_carry_basis = (rot * _carry_basis).orthonormalized()

## Where the crate would be put down right now, from the player's replicated aim. Shared by the tick
## (for the E prompt) and the drop itself; the owner's client runs the very same resolution to draw
## the placement disc, so what it shows is what lands here.
func _resolve_placement() -> Dictionary:
	var excl: Array[RID] = [player.get_rid()]
	if player.hands_item is CollisionObject3D:
		excl.append(player.hands_item.get_rid())
	return CarryPlacement.resolve(player.get_world_3d().direct_space_state,
			player.camera_pivot.global_transform, player.up_direction, excl, get_tree(),
			player.hands_item)

## Server: hold the carried crate RIGIDLY on its body mount and keep the placement disc up to date.
## Re-asserting the local pose every tick costs nothing and makes the hold immune to anything that
## nudges the body (a physics wake-up, a replicated pose landing late).
func _server_update_carried_item(_delta: float) -> void:
	if player.hands_item == null:
		return
	player.hands_item.transform = Transform3D(_carry_basis, player.carry_mount_offset)
	_place = _resolve_placement()

## Drain the dialog queue: release the OLDEST pending line every _DIALOG_LINE_INTERVAL seconds, then
## clear the bubble with a single null once nothing is left to say.
##
## The timer is only spent while there is something to do, so a silent NPC costs one is_empty() check
## per tick and, more importantly, an idle queue leaves the timer at/below zero — the FIRST line of a
## new conversation therefore goes out on the very next tick instead of making the player wait 2 s for
## a greeting. Subsequent lines are properly spaced because sending a line rearms the timer.
func _server_update_dialog(delta: float) -> void:
	if _dialog_queue.is_empty() and not _dialog_active:
		return  # nothing to say, and the clearing null has already gone out
	_dialog_timer -= delta
	if _dialog_timer > 0.0:
		return  # the current line has not had its time on screen yet
	print("2 seconds?")
	if _dialog_queue.is_empty():
		# Said everything: wipe the bubble. _dialog_active going false means this branch is not
		# reachable again until a new line is queued, so the null is sent ONCE, not every 2 s.
		print("end")
		player.server_send_properties_to_client({"conversation": null})
		_dialog_active = false
		return
	print(_dialog_queue)
	player.server_send_properties_to_client({"conversation": _dialog_queue.pop_front()})
	_dialog_active = true
	_dialog_timer = _DIALOG_LINE_INTERVAL

## Server-authoritative carry prompt: the server (which owns the collisions) decides what E
## will do from the player's replicated aim, and replicates "carry"/"drop"/"" to the owner —
## the client just displays it. Throttled so it's cheap (one ray per player, not per object).
func _server_update_carry_prompt(delta: float) -> void:
	_carry_prompt_timer -= delta
	if _carry_prompt_timer > 0.0:
		return
	_carry_prompt_timer = 0.1
	var state := _compute_carry_prompt()
	if state != player._carry_prompt:
		player._carry_prompt = state
		player.server_send_properties_to_client({"carry_prompt": state})

## What E would do right now (server side): if we hold something, "cargo" when the drop would load
## it onto a truck (it sticks), else "drop"; if our hands are empty, "carry" when we aim at a
## grabbable prop that is reachable (not carried by another, clear line of sight).
func _compute_carry_prompt() -> String:
	if player.hands_item != null:
		# The PLACEMENT point decides, not where the crate rides: it sits on our chest now, while E
		# puts it down on the disc under the crosshair (which may be metres away, in a bed or a slot).
		var point: Vector3 = _place["position"] if _place.has("position") else player.global_position
		if _cargo_bed_for_drop(point) != null:
			return "cargo"  # dropping here loads it into the bed (sticks)
		if _place.get("shelf") != null:
			return "cargo"  # dropping here snaps it into a shelf slot (sticks)
		return "drop"
	if _stance != 0:
		return ""  # standing only: no "pick up" prompt while crouched or prone
	player.interact_ray.force_raycast_update()
	var prop = player._aimed_carriable()
	if prop != null and prop.has_method("interact") and prop.interact(player) \
			and not _is_blocked_by_geometry(prop):
		return "carry"
	return ""

## Which truck bed should swallow a crate dropped at this world point: any truck whose designer
## loading zone contains it. Same rule whether we stand in the bed or reach over from outside — the
## zone (not the player's position) decides whether loading is allowed.
func _cargo_bed_for_drop(world_point: Vector3) -> Vehicle:
	for v in get_tree().get_nodes_in_group("vehicle"):
		if v is Vehicle and v.is_point_in_loading_zone(world_point):
			return v
	return null

## Which shelf should swallow a crate dropped at this world point: any shelf with a free slot within
## snap range of it (see shelf.gd). Returns the shelf node (StaticBody3D) so the caller can store into
## it, or null when no shelf slot is in reach.
func _shelf_for_drop(world_point: Vector3) -> Node:
	var nearest: Node = null
	var nearest_dist_sq := INF
	for s in get_tree().get_nodes_in_group("shelf"):
		if not (s is Node3D) or not s.has_method("can_store"):
			continue
		if s.global_position.distance_squared_to(player.global_position) > _SHELF_DROP_RANGE * _SHELF_DROP_RANGE:
			continue
		var dist_sq: float = s.global_position.distance_squared_to(world_point)
		if dist_sq < nearest_dist_sq:
			nearest_dist_sq = dist_sq
			nearest = s
	if nearest != null and nearest.can_store(world_point):
		return nearest
	return null

## Safety net for CharacterBody tunnelling through the thin trimesh terrain on
## a fast fall.  Only acts when the player is CLEARLY below the crack-aware
## surface (a real fall-through) — normal standing rests on the polygon
## collision within the margin, so this never fires then and doesn't affect
## is_on_floor / jumping.  [param area] is the planet gravity Area3D.
func _catch_if_below_surface(area: Area3D) -> void:
	var planet := area.get_parent().get_parent()
	if planet == null or not is_instance_valid(planet):
		return
	if not planet.has_method("get") or planet.get("planet_data") == null:
		return
	var pdata = planet.planet_data
	if pdata == null:
		return
	var local_world: Vector3 = player.global_position - planet.global_position
	if local_world.length_squared() < 1.0:
		return
	var planet_basis: Basis = planet.global_transform.basis
	var local_body: Vector3 = planet_basis.inverse() * local_world
	var dir: Vector3 = local_body.normalized()
	var player_dist: float = local_body.length()
	var surface_dist: float = pdata.crack_aware_surface_dist(dir)
	if player_dist >= surface_dist - player._SURFACE_CATCH_MARGIN:
		return  # at/near or above the surface — the collision handles it
	player.global_position = planet.global_position + planet_basis * (dir * surface_dist)
	var up_world: Vector3 = (planet_basis * dir).normalized()
	var radial: float = player.velocity.dot(up_world)
	if radial < 0.0:
		player.velocity -= up_world * radial

## Deferred teleport onto a system (e.g. a teleporter target): reparent under
## `destination`, place the player at `local_pos` expressed in that node's frame,
## then emit the move AFTER the reparent so the server receives the position
## relative to the new parent. Deferred because reparenting during an Area3D
## signal callback is illegal, and the callback can fire repeatedly.
func _teleport_to_system(destination: Node, local_pos: Vector3) -> void:
	if destination == null or not is_instance_valid(destination):
		return
	if not player.is_inside_tree() or not destination.is_inside_tree():
		return
	if player.get_parent() != destination:
		player.npc_goal_keep_world(destination)
		player.reparent(destination)
	# Test without parent, to have the planet gorc enter on client side.
	# The offset goes through the destination's BASIS, so it really is expressed in that node's frame:
	# on a spinning planet a world-axes offset would keep the landing spot fixed in space while the
	# ground turned underneath, and the pad would drift a full circle of longitude every day.
	player.global_position = destination.global_position + destination.global_basis * local_pos
	# BUG FIXED IN PASSING: this emitted on `self` (PlayerServer, a plain Node that does NOT declare
	# hs_server_move) instead of on the body, so the teleport reparent was never replicated at all.
	# Going through the body's single emitter removes the whole class of mistake.
	player.emit_move()
