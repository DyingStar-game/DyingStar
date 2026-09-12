class_name TeleportGround
extends RefCounted

## Turns a [TeleportDestination] into a position in a planet's own frame. SERVER side: where a body
## lands is an authority decision, so it is taken against the same terrain the collision is built
## from, never against whatever the client believed.
##
## Best effort on the elevation tile, then an HONEST report of what was actually used.
##
## PlanetData.sample_height_for_direction() never touches the network, so a tile that is not on disk
## sends it down the PYRAMID to a coarser level. That is not a failure — the ground still comes from
## real data, just less finely — and the landing is computed with crack_aware_surface_dist(), which is
## the very function the server's own anti-tunnel clamp measures against. The arrival therefore agrees
## with the collision BY CONSTRUCTION, whatever level answered.
##
## An earlier version refused to teleport whenever the finest tile could not be fetched. It was
## measured wrong on 2026-09-10: every trip was rejected with "TILE MISSING" even though tarsis_3 has
## 2896 tiles cached and serves n1..n1024 — the finest tile for that one pixel simply is not published.
## Refusing on that is testing the wrong thing. So: fetch when we can, say what happened, and leave a
## little more air under a landing we could not sharpen.
## Where the height data came from. Used for the log line, and to refuse a landing we cannot trust.
enum Tile {
	READY,  ## the finest tile is on disk, freshly fetched or already cached
	NO_STREAM,  ## no tile service for this body; a local heights.pack may still answer
	COARSE,  ## the finest tile could not be secured — the height comes from a coarser pyramid level
}

## Extra metres of air under a landing whose finest tile we could not secure. Small on purpose: the
## coarser level is still real data, and PlayerServer holds the body until the ground exists anyway.
const COARSE_MARGIN_M: float = 3.0


## Position of [param dest] in [param planet]'s own frame, ready for PlayerServer.teleport_to().
## [param tile_out] receives the [enum Tile] outcome, so the caller can log or refuse.
static func local_pos_for(planet: Planet, dest: TeleportDestination,
		tile_out: Array = []) -> Vector3:
	var data: PlanetData = planet.planet_data
	var dir: Vector3 = HEALPix.lonlat2vec(dest.lon, dest.lat)
	if data == null:
		push_warning("[TeleportGround] %s has no PlanetData — cannot resolve a height" % planet.name)
		tile_out.append(Tile.COARSE)
		return dir * dest.height
	# Sea-level mode asks for a height above the reference radius, which is a pure number: no terrain
	# is involved, so no tile is needed. This is the orbit case, and the one that must never block.
	if dest.height_mode == TeleportDestination.Height.SEA:
		tile_out.append(Tile.READY)
		return dir * (data.radius + dest.height)
	var outcome: Tile = ensure_tile(data, dir)
	tile_out.append(outcome)
	var margin: float = COARSE_MARGIN_M if outcome == Tile.COARSE else 0.0
	# crack_aware_surface_dist is the authoritative ground: it is what the server's own anti-tunnel
	# clamp measures against, so landing on it agrees with the collision by construction.
	return dir * (data.crack_aware_surface_dist(dir) + dest.height + margin)


## Make the elevation tile covering [param dir] resident, and say how that went.
##
## Blocking on purpose. fetch_now() is forbidden on the meshing path — this is not it: it runs once,
## from a deliberate user action, and the alternative is landing on a height nobody measured.
static func ensure_tile(data: PlanetData, dir: Vector3) -> Tile:
	var source: RemoteTileSource = data.remote_source
	if source == null:
		return Tile.NO_STREAM
	var nside: int = data.export_nside
	if nside <= 0 or not source.serves(nside):
		return Tile.NO_STREAM
	var ipix: int = HEALPix.vec2pix_nest(nside, dir)
	# fetch_now() checks the disk cache itself, so an already-cached tile costs nothing here. has_tile()
	# is deliberately NOT called alongside it: it is documented as blocking and reserved for the
	# download thread, and calling it from here stalls the server on a shard map.
	return Tile.READY if source.fetch_now(nside, ipix) else Tile.COARSE


static func tile_text(outcome: int) -> String:
	match outcome:
		Tile.READY:
			return "finest tile ready"
		Tile.NO_STREAM:
			return "no tile stream (local pack or nothing)"
		_:
			return "coarser pyramid level, +%.0f m of clearance" % COARSE_MARGIN_M
