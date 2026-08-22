class_name MiningZonePlanner
extends RefCounted

## Server-side seeder for mining zones: it decides which HEALPix terrain chunks carry an ore
## deposit, and spawns the networked MiningZone that populates them.
##
## One zone per COLLISION chunk (PlanetData.collision_detail_nside — n8192, ~794 m on tarsis_4),
## centred on the chunk. Its field spans PlanetData.mining_zone_chunk_fill of that chunk and holds
## PlanetData.mining_zone_rock_density rocks per km², both DERIVED here (zone_size_for /
## rock_count_for) so the deposits follow the terrain LOD instead of being hand-tuned per planet.
##
## Everything here is DERIVED, never stored: the same (planet uuid, chunk key) yields the same
## verdict, the same uuid, the same mineral, on every server and after every restart. That is what
## makes "has this chunk already been done?" answerable without a database — a barren chunk is
## re-derived for free, and a chunk that DID get a zone is recognised because the zone itself came
## back through Horizon's replay under its deterministic uuid.
##
## Detection is armed from here too. Horizon replays every stored zone at boot; on a seeded planet
## that is hundreds of MiningZone nodes, and letting each run its own _physics_process is the exact
## O(zones) cost that already sank this server once (see MiningZone's DETECT_INTERVAL_FRAMES note).
## The planner arms only the zone under a player, and disarms it when they leave: O(players).

## Above this height (m) OVER THE LOCAL GROUND, a player is flying over rather than walking on the
## chunk, and seeding it would persist a zone nobody is going to mine.
##
## This is height above the terrain, not distance from sea level: Planet.surface_altitude_of
## subtracts the sampled elevation, so a player standing on a 5 km plateau reads ~0 and a player at
## the bottom of a 180 m crack reads ~-180. The terrain's own elevation never enters into it.
##
## Deliberately generous. The threshold only has to separate "on foot" from "cruising past", and
## being too tight is the dangerous direction: PlanetData.sample_height_for_direction falls back to
## the equirectangular map — "a different (usually flatter) surface" — whenever a chunk tile is
## missing at sample time, which can throw the reading off by hundreds of metres and would then
## block seeding everywhere with no symptom. _log_altitude_skip exists so that failure is never
## silent if it happens anyway.
const PLAN_MAX_ALTITUDE := 2000.0

## Cap on the "too high to seed" log lines, so a player crossing chunks at cruise speed cannot flood
## the server log. Mirrors Server.PIN_DEBUG_MAX.
const ALTITUDE_SKIP_LOG_MAX := 10

## Cap on the memoised verdicts. The dictionary only avoids re-running the filters, and every
## verdict is re-derivable from the seed, so dropping the whole thing is always safe — it just costs
## one more evaluation next time. Without the cap a player crossing the planet in a ship would grow
## it without bound.
const MAX_EVALUATED := 20000

## Upper bound on the rocks one zone may queue. MiningZone releases them one per
## SPAWN_INTERVAL_FRAMES (10) physics frames so Horizon's channel never overflows, so 400 rocks
## already take over two minutes to appear — and each is a networked, persisted body. A density that
## asks for more is almost certainly a typo, so clamp and say so rather than grinding.
const MAX_ROCKS_PER_ZONE := 400

## Horizon's zone channel; also the key MiningZone's PropSync declares.
const ZONE_TYPE := "miningzone"

## Server.props_list, bound once. Read through .get() every time because the per-type sub-dictionary
## is created lazily on the first prop of that type (Server.create_generic_object).
var _props_list: Dictionary = {}

var _evaluated: Dictionary = {}      # "<planet_uuid>|<zone_key>" -> true (verdict already rendered)
## player_uuid -> the zone uuid of the chunk they stand on. Keyed by the DERIVED zone uuid rather
## than the chunk key so it doubles as "which zone must stay armed" — two chunks can never collide
## on one uuid, and a chunk with no deposit simply maps to a uuid no node answers to.
var _player_chunk: Dictionary = {}
var _armed: Dictionary = {}          # zone_uuid -> true (detection currently running)
var _seen_this_sweep: Dictionary = {}  # player uuids visited between begin_sweep and end_sweep
var _banner_shown: Dictionary = {}   # planet_uuid -> true (the one-time "planner is live" line)
var _seeded_count: int = 0           # zones seeded this session, reported in the seed log
var _altitude_skips: int = 0         # chunks skipped for altitude (logged up to the cap)


## Bind Server.props_list. The Dictionary itself is stable for the server's lifetime; only its
## per-type entries come and go.
func bind_props_list(props_list: Dictionary) -> void:
	_props_list = props_list


## Open a sweep. Players are then rediscovered from scratch, so a uuid that stops being offered —
## disconnected, teleported off-planet, handed to another shard — drops out on its own at
## end_sweep(). Deriving liveness from the sweep beats hooking every place the server erases a
## player: there are four of them, and a missed one would leave a zone armed forever.
func begin_sweep() -> void:
	_seen_this_sweep.clear()


## Close a sweep: forget players nobody offered, and release the zones they were holding armed.
func end_sweep() -> void:
	for player_uuid in _player_chunk.keys():
		if not _seen_this_sweep.has(player_uuid):
			_player_chunk.erase(player_uuid)
	_disarm_unused()


## Called once per player per pin sweep. Cheap by design: it resolves the chunk under the player and
## returns immediately unless that chunk CHANGED, so the steady state costs one HEALPix lookup.
func plan_for_player(planet: Planet, player: Node3D, player_uuid: String) -> void:
	if planet == null or planet.planet_data == null or planet.planet_terrain == null:
		return
	if not planet.planet_data.mining_zones_enabled:
		return
	_seen_this_sweep[player_uuid] = true
	_log_banner(planet)
	var zone_key: String = planet.planet_terrain.collision_chunk_key(player.global_position)
	if zone_key == "":
		return
	var zone_uuid: String = zone_uuid_for(planet.uuid, zone_key)
	if _player_chunk.get(player_uuid, "") == zone_uuid:
		# Still on the same chunk — the common case. Retry arming anyway when the zone is not armed
		# yet: on the entry tick the node may not have existed (Server.create_generic_object defers
		# a prop whose parent is not resolvable yet). Without this retry a zone spawned under a
		# STANDING player would sit dormant until they walked away and came back. A barren chunk
		# maps to a uuid no node answers to, so this costs one dictionary lookup.
		if not _armed.has(zone_uuid):
			_arm(zone_uuid)
		return

	_player_chunk[player_uuid] = zone_uuid
	var altitude: float = planet.surface_altitude_of(player.global_position)
	if altitude > PLAN_MAX_ALTITUDE:
		_log_altitude_skip(zone_key, altitude)
		return  # flying over: don't persist a zone under a player who is not landing on it
	if _ensure_zone(planet, zone_key, zone_uuid) != "":
		_arm(zone_uuid)


# ── The decision ──────────────────────────────────────────────────────────────

## Make sure the chunk [param zone_key] has its mining zone, if it deserves one. Returns the zone's
## uuid when a zone exists there (already or as of this call), "" when the chunk carries no deposit.
func _ensure_zone(planet: Planet, zone_key: String, zone_uuid: String) -> String:
	var data: PlanetData = planet.planet_data

	# Already there? Either we spawned it earlier this session, or Horizon replayed it at boot under
	# the same deterministic uuid. Either way the chunk is done — this is the "don't do it twice"
	# check, and it needs no extra persisted state of its own.
	var zones: Dictionary = _props_list.get(ZONE_TYPE, {})
	if zones.has(zone_uuid):
		_mark_evaluated(planet.uuid, zone_key)
		return zone_uuid

	var memo_key := "%s|%s" % [planet.uuid, zone_key]
	if _evaluated.has(memo_key):
		return ""  # verdict already rendered this session: this chunk is barren

	_mark_evaluated(planet.uuid, zone_key)

	if not has_deposit(planet.uuid, zone_key, data.mining_zone_deposit_rate):
		return ""

	var key := _parse_zone_key(zone_key)
	if key.y < 0:
		return ""
	var nside: int = key.x
	var ipix: int = key.y

	# Chunk centre, on the ground. Sampled from the heightmap pyramid rather than raycast: the
	# collision body for this chunk may still be loading, and the pyramid is the surface it is
	# built from anyway. MiningZone does its own raycasts later, when it places each rock.
	var dir: Vector3 = HEALPix.pix2vec_nest(nside, ipix)
	var local_pos: Vector3 = planet.planet_terrain.surface_point_for_direction(dir)
	var world_pos: Vector3 = planet.global_transform * local_pos
	var zone_size: float = zone_size_for(nside, data.radius, data.mining_zone_chunk_fill)
	var rock_count: int = rock_count_for(zone_size, data.mining_zone_rock_density)
	var half: float = zone_size * 0.5

	# The zone's CENTRE must clear the POI by the margin and no more. The field may then still
	# overhang the sphere — MiningZone culls the individual rocks that land inside it, so a deposit
	# can sit right up against a village instead of being pushed a whole half-field away.
	var poi_hit: Dictionary = PlanetTerrain.first_blocking_poi(
		world_pos, planet.planet_terrain.poi_spheres(), data.mining_zone_poi_margin)
	if not poi_hit.is_empty():
		print("[MiningZone] %s skipped: inside POI '%s' (d=%.0fm radius=%.0fm margin=%.0fm)" % [
			zone_key, poi_hit["name"], poi_hit["distance"], poi_hit["radius"],
			data.mining_zone_poi_margin])
		return ""
	if _road_blocks(data, dir, nside, ipix, half + data.mining_zone_road_margin):
		print("[MiningZone] %s had a deposit but a road crosses it — skipped." % zone_key)
		return ""

	# +Y along the local radial. `rotation` travels parent-local and the planet's +Y is the POLE, so
	# a zero euler would lay the zone on its side everywhere but at the pole — and MiningZone casts
	# its ground rays along its own +Y. See PropSpawn.surface_euler.
	var up_world: Vector3 = planet.global_transform.basis.orthonormalized() * dir
	var rot: Vector3 = PropSpawn.surface_euler(
		up_world, 0.0, planet.global_transform.affine_inverse())

	var mineral: String = pick_mineral(planet.uuid, zone_key,
		data.mining_zone_minerals, data.mining_zone_mineral_weights)
	var richness: float = pick_richness(planet.uuid, zone_key,
		data.mining_zone_richness_min, data.mining_zone_richness_max)

	# World infrastructure: shield it from the admin cleanup tool, as designer-placed zones are.
	NetworkOrchestrator.protected_prop_uuids[zone_uuid] = true
	NetworkOrchestrator.spawn_prop_authoritative({
		"type": ZONE_TYPE,
		"uuid": zone_uuid,
		"scenename": MiningZone.SCENE_PATH,
		"parent_id": planet.uuid,
		"position": {"x": local_pos.x, "y": local_pos.y, "z": local_pos.z},
		"rotation": {"x": rot.x, "y": rot.y, "z": rot.z},
		"zone_size": zone_size,
		"rock_count": rock_count,
		"min_spacing": data.mining_zone_min_spacing,
		"weight_small": data.mining_zone_weight_small,
		"weight_medium": data.mining_zone_weight_medium,
		"weight_large": data.mining_zone_weight_large,
		"richness": richness,
		"richness_spread": 0.12,
		"mineral_id": mineral,
		"generated": false,
		"last_generation_datetime": 946724400,  # 2000-01-01 UTC, MiningZone's "never" sentinel
	})
	_seeded_count += 1
	var lonlat: Vector2 = HEALPix.vec2lonlat(dir)
	print("[MiningZone] seeded #%d %s mineral=%s richness=%.2f lon=%.4f lat=%.4f uuid=%s" % [
		_seeded_count, zone_key, mineral, richness, lonlat.x, lonlat.y, zone_uuid])
	return zone_uuid


## One line, once per planet, the first time a player is planned on it. Without it there is no way
## to tell "no zone appeared because this stretch is barren" from "no zone appeared because the
## planner never ran" — and at a 15% rate the first is by far the more common.
func _log_banner(planet: Planet) -> void:
	if _banner_shown.has(planet.uuid):
		return
	_banner_shown[planet.uuid] = true
	var data: PlanetData = planet.planet_data
	var nside: int = data.collision_detail_nside()
	var chunk_side: float = HEALPix.pixel_side_length(nside, data.radius)
	var zone_size: float = zone_size_for(nside, data.radius, data.mining_zone_chunk_fill)
	print(("[MiningZone] planner live on %s: rate=%.0f%% chunk=%.0fm zone=%.0fm (fill %.0f%%) "
		+ "rocks=%d (%.0f/km²) minerals=%s host_rock=%s") % [
		data.planet_name, data.mining_zone_deposit_rate * 100.0, chunk_side, zone_size,
		data.mining_zone_chunk_fill * 100.0,
		rock_count_for(zone_size, data.mining_zone_rock_density), data.mining_zone_rock_density,
		", ".join(data.mining_zone_minerals), data.mining_zone_host_rock])


## Report the altitude gate, capped. A player who really is flying produces these and can ignore
## them; a player who is WALKING and still sees them is looking at a bad height sample, which is the
## whole reason this is logged rather than skipped in silence.
func _log_altitude_skip(zone_key: String, altitude: float) -> void:
	_altitude_skips += 1
	if _altitude_skips > ALTITUDE_SKIP_LOG_MAX:
		return
	print("[MiningZone] %s skipped: player is %.0f m above the ground (limit %.0f)%s" % [
		zone_key, altitude, PLAN_MAX_ALTITUDE,
		" — further such lines suppressed" if _altitude_skips == ALTITUDE_SKIP_LOG_MAX else ""])


func _mark_evaluated(planet_uuid: String, zone_key: String) -> void:
	if _evaluated.size() >= MAX_EVALUATED:
		_evaluated.clear()  # safe: every verdict is re-derivable from the seed
	_evaluated["%s|%s" % [planet_uuid, zone_key]] = true


# ── Deterministic draws ───────────────────────────────────────────────────────

## Side length (m) of a zone's square field on a chunk at [param nside]: the chunk's own
## equal-area equivalent side, scaled by [param fill]. Derived rather than configured so the field
## tracks the terrain LOD instead of drifting out of step with it.
static func zone_size_for(nside: int, radius: float, fill: float) -> float:
	return HEALPix.pixel_side_length(nside, radius) * clampf(fill, 0.0, 1.0)


## How many rocks a field of [param zone_size] metres holds at [param density] rocks per km².
## Clamped: at least one rock (an empty deposit is not a deposit), and never more than the spawn
## throttle can deliver in a sane time.
static func rock_count_for(zone_size: float, density: float) -> int:
	var count: int = int(round(zone_size * zone_size / 1_000_000.0 * maxf(density, 0.0)))
	if count > MAX_ROCKS_PER_ZONE:
		push_warning(("[MiningZonePlanner] density %.0f/km² over a %.0f m field wants %d rocks; "
			+ "clamped to %d.") % [density, zone_size, count, MAX_ROCKS_PER_ZONE])
		return MAX_ROCKS_PER_ZONE
	return maxi(count, 1)


## The zone's uuid for this chunk. Deterministic so Horizon UPSERTS: a restart replays the existing
## zone (with its `generated` state intact) instead of stacking a second one on the same ground.
static func zone_uuid_for(planet_uuid: String, zone_key: String) -> String:
	return PropSpawn.stable_uuid("%s|miningzone|%s" % [planet_uuid, zone_key])


## Does this chunk carry a deposit? A pure function of the seed, so the answer never has to be
## stored — a barren chunk costs nothing in the database, which is what lets the planner sample the
## whole planet instead of paving it.
static func has_deposit(planet_uuid: String, zone_key: String, rate: float) -> bool:
	if rate <= 0.0:
		return false
	if rate >= 1.0:
		return true
	return _unit_hash("%s|deposit|%s" % [planet_uuid, zone_key]) < rate


## Ore richness for this chunk, drawn from [param lo]..[param hi]. Replicated per zone, and from
## there it steers each rock's ore_seed (MiningZone._ore_seed_for_richness).
static func pick_richness(planet_uuid: String, zone_key: String, lo: float, hi: float) -> float:
	var a: float = minf(lo, hi)
	var b: float = maxf(lo, hi)
	return a + (b - a) * _unit_hash("%s|richness|%s" % [planet_uuid, zone_key])


## Which mineral this chunk yields, drawn from the planet's weighted table. Ids absent from
## MineralRegistry are skipped rather than shipped: an unknown id would only surface much later, as
## a warning per rock at mining time.
static func pick_mineral(planet_uuid: String, zone_key: String,
		ids: PackedStringArray, weights: PackedFloat32Array) -> String:
	var valid: PackedStringArray = PackedStringArray()
	var valid_w: PackedFloat32Array = PackedFloat32Array()
	var total: float = 0.0
	for i in ids.size():
		var id: String = ids[i]
		if not MineralRegistry.has_mineral(StringName(id)):
			push_warning("[MiningZonePlanner] unknown mineral '%s' in mining_zone_minerals — skipped." % id)
			continue
		var w: float = weights[i] if i < weights.size() else 1.0
		if w <= 0.0:
			continue
		valid.append(id)
		valid_w.append(w)
		total += w
	if valid.is_empty():
		# Every deposit on the planet then yields iron. That is a configuration accident, not a
		# design choice — an editor re-save has been seen to blank these arrays — so say so.
		push_warning("[MiningZonePlanner] mining_zone_minerals holds no usable id; "
			+ "every deposit will yield iron. Check the planet's PlanetData.")
		return "iron"
	var r: float = _unit_hash("%s|mineral|%s" % [planet_uuid, zone_key]) * total
	var acc: float = 0.0
	for i in valid.size():
		acc += valid_w[i]
		if r < acc:
			return valid[i]
	return valid[valid.size() - 1]


## A stable 0..1 draw from a seed string, via the top 32 bits of its SHA-256.
##
## String.hash() is NOT usable here. It is a djb2, so two seeds differing only in their last
## characters hash to values one apart — "…|p1000" and "…|p1001" land 1/2^32 from each other. Since
## neighbouring chunks differ by exactly that, the draw would be effectively constant across any
## region a player can walk, and the planet would come out in solid blocks of all-deposit and
## all-barren instead of a 15% scatter. SHA-256 avalanches; it costs microseconds and only runs when
## a player steps onto a new chunk.
static func _unit_hash(seed_str: String) -> float:
	return float(seed_str.sha256_text().substr(0, 8).hex_to_int()) / 4294967296.0


# ── Exclusions ────────────────────────────────────────────────────────────────

## True when a road runs through the chunk close enough that a field of half-extent [param margin]
## would swallow it. Reuses the same pair the three vegetation spawners use — get_roads_for_chunk
## resolves the modifier pyramid level for us, point_on_any_road does the polyline distance.
func _road_blocks(data: PlanetData, dir: Vector3, nside: int, ipix: int, margin: float) -> bool:
	var roads: Array = data.get_roads_for_chunk(nside, ipix)
	if roads.is_empty():
		return false
	var lonlat: Vector2 = HEALPix.vec2lonlat(dir)
	return RoadTerrain.point_on_any_road(
		lonlat.x, lonlat.y, roads, data.radius * PI / 180.0, margin)


# ── Arming ────────────────────────────────────────────────────────────────────

func _arm(zone_uuid: String) -> void:
	if _armed.has(zone_uuid):
		return
	var zone := _zone_node(zone_uuid)
	if zone == null:
		# Freshly spawned: the node exists only after Server.create_generic_object has added it, and
		# on the very first sweep that may not have happened yet. The next chunk change re-arms it,
		# and MiningZone.apply_prop_data has already stored the field config either way.
		return
	_armed[zone_uuid] = true
	zone.enable_server_detection()
	print("[MiningZone] armed %s — waiting for a player within %.0f m of its centre" % [
		zone_uuid, zone.zone_size * 0.5 + MiningZone.DETECT_MARGIN])


## Disarm every armed zone no player stands on any more. Checking the whole set (rather than just
## the chunk the mover left) is what keeps a zone armed while a SECOND player is still inside it.
func _disarm_unused() -> void:
	var wanted: Dictionary = {}
	for player_uuid in _player_chunk:
		wanted[_player_chunk[player_uuid]] = true
	for zone_uuid in _armed.keys():
		if wanted.has(zone_uuid):
			continue
		var zone := _zone_node(zone_uuid as String)
		if zone != null:
			zone.disable_server_detection()
		_armed.erase(zone_uuid)


func _zone_node(zone_uuid: String) -> MiningZone:
	var zones: Dictionary = _props_list.get(ZONE_TYPE, {})
	var node: Variant = zones.get(zone_uuid)
	return node as MiningZone if is_instance_valid(node) else null


## Parse "hp_n<NSIDE>_p<IPIX>" back into (nside, ipix); y = -1 on a malformed key. Mirrors
## PlanetTerrain._chunk_key_hp — the key is produced by collision_chunk_key and read here, so the
## two must agree on the format (as planet_data.gd and server.gd already do).
static func _parse_zone_key(zone_key: String) -> Vector2i:
	var parts: PackedStringArray = zone_key.split("_")
	if parts.size() < 3 or not parts[1].begins_with("n") or not parts[2].begins_with("p"):
		return Vector2i(0, -1)
	return Vector2i(int(parts[1].substr(1)), int(parts[2].substr(1)))
