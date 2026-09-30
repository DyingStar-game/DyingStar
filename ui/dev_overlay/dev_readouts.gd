class_name DevReadouts
extends RefCounted
## What the debug panel's sections say, as pure functions: data in, lines out. The panel (DevOverlay)
## decides when and where; these only format — so each is tested without a panel or a server.

## The Server box's zone names, and its axis captions (the table of bounds, from TheMoye's #330).
const ZONE_NAME_COLOR : String = "#ffd75e"
const AXIS_COLOR : String = "#888888"
const _COLUMN_GAP_PX : int = 18


# ── Alert ───────────────────────────────────────────────────────────────────────────────────────

## The dev clock (+ / -, Globals.debug_time_offset) is THIS client's alone, on purpose: it is for
## looking at an atmosphere at another hour, and the server never learns of it. Everything the server
## works out from the time then disagrees with what this client draws — an orbital station stands
## somewhere else, and leaving it lands you where the SERVER has it. Hence an alert, shown whether the
## debug panels are on or not.
static func clock_alert_active() -> bool:
	return not is_zero_approx(Globals.debug_time_offset)


static func clock_alert_text(offset_s: float) -> String:
	if is_zero_approx(offset_s):
		return ""
	return String(TranslationServer.translate("%%HUD_DEV_CLOCK_WARNING")) % (offset_s / 3600.0)


static func clock_alert_lines() -> PackedStringArray:
	return [clock_alert_text(Globals.debug_time_offset)]


# ── Universe ────────────────────────────────────────────────────────────────────────────────────

static func universe_lines(body: Node3D, cache: ServerInfoCache) -> PackedStringArray:
	var out : PackedStringArray = [
		"%s servers" % str(cache.value("universe_servers", "-")),
		"%s players" % str(cache.value("universe_players", "-")),
		planet_time(body),
	]
	out.append_array(where(body))
	return out


## Local solar time on the body we belong to — so it follows you from planet to moon, and says
## "space" in between. Planet.get_local_solar_time is a sundial: no clock is synchronised for this.
static func planet_time(body: Node3D) -> String:
	if not is_instance_valid(body):
		return "-- : --"
	var planet : Planet = Planet.of(body)
	if planet == null:
		return "space"
	var hours : float = planet.get_local_solar_time(body.global_position)
	if hours < 0.0:
		return "-- : --"  # not spinning, no star, or standing on a pole
	var text : String = "%02d:%02d %s" % [int(hours), int((hours - floorf(hours)) * 60.0), planet.name]
	# A nudged clock must SAY so: an hour that does not match the authority's is the kind of thing one
	# forgets having set, and then debugs for twenty minutes.
	if not is_zero_approx(Globals.debug_time_offset):
		text += "  (%+.1f h dev)" % (Globals.debug_time_offset / 3600.0)
	return text


## Altitude, position and moving frame: three lines.
static func where(body: Node3D) -> PackedStringArray:
	if not is_instance_valid(body):
		return ["alt --"]
	var planet : Planet = Planet.of(body)  # the body we belong to, not the one whose gravity holds us
	var out : PackedStringArray = []
	if planet == null:
		out.append("alt --  (deep space)")
	elif planet.planet_data == null:
		out.append("alt --")
	else:
		# TWO heights, because either alone lies: `elevation` above the reference sphere is what an
		# altimeter reads; `clearance` to the ground under your feet is ~0 wherever you stand.
		var here : Vector3 = body.global_position
		var elevation : float = planet.elevation_of(here)
		var top : float = planet.planet_data.get_atmosphere_top()
		var in_air : bool = top > 0.0 and elevation <= top
		out.append("alt %s  ·  sol %s  (%s)" % [ReadoutFormat.metres(elevation),
			ReadoutFormat.signed(planet.surface_altitude_of(here)), "atmosphere" if in_air else "space"])
		var lonlat : Vector2 = planet.lonlat_of(here)
		out.append("%.4f° %s  %.4f° %s" % [absf(lonlat.y), "N" if lonlat.y >= 0.0 else "S",
			absf(lonlat.x), "E" if lonlat.x >= 0.0 else "O"])
	out.append(frame(body))
	return out


## The scene-graph parent carrying the body — the MOVING FRAME — with its uuid, since that is what
## travels as parent_id. NO UUID is the one to watch: positions go out declared world-relative then.
static func frame(body: Node3D) -> String:
	var parent : Node = body.get_parent()
	if not is_instance_valid(parent):
		return "frame: (none)"
	var uuid : String = str(parent.uuid) if "uuid" in parent else ""
	return "frame: %s [lb]%s]" % [ReadoutFormat.escape(parent.name), uuid.substr(0, 8) if uuid != "" else "NO UUID"]


# ── Server ──────────────────────────────────────────────────────────────────────────────────────

static func server_lines(cache: ServerInfoCache) -> PackedStringArray:
	var tps : Variant = cache.value("tps")
	return [
		ReadoutFormat.rated(float(tps), 30.0, "TPS") if tps != null else "- TPS",
		"%s players" % _count(cache.value("server_players")),
		"%s objects" % _count(cache.value("server_objects")),
		"%s scenes" % _count(cache.value("server_scenes")),
		"%s active scenes" % _count(cache.value("server_active_scenes")),
	]


## A server count as an integer — JSON hands every number over as a float ("1234.0") — or "-" until
## the server has sent it.
static func _count(v: Variant) -> String:
	return "-" if v == null else str(int(v))


## The Godot server simulating us, and its zones — all of them: the section caps its height and
## scrolls on its own (DevOverlay), so a long list no longer runs over the next section.
static func box_lines(cache: ServerInfoCache) -> PackedStringArray:
	var out : PackedStringArray = ["server name: %s" % ReadoutFormat.escape(str(cache.value("server_name", "-")))]
	for zone in cache.value("zones", []):
		out.append(zone_block(zone))
	return out


## Its world (space or a planet), then "(whole)" or its bounds in that world's coordinates as a
## table — one row per axis, min and max right-aligned, thousands apart.
static func zone_block(zone: Dictionary) -> String:
	var name : String = str(zone.get("world", "?"))
	if name == "planet":
		name += " " + str(zone.get("planet_name", zone.get("planet_uuid", "?")))
	var head : String = "[color=%s]%s[/color]" % [ZONE_NAME_COLOR, ReadoutFormat.escape(name)]
	var b : Variant = zone.get("bounds")
	if b == null:
		return head + " (whole)"
	return head + "\n[table=3]%s%s%s[/table]" % [
		_axis_row("X", b.get("min_x", 0.0), b.get("max_x", 0.0)),
		_axis_row("Y", b.get("min_y", 0.0), b.get("max_y", 0.0)),
		_axis_row("Z", b.get("min_z", 0.0), b.get("max_z", 0.0))]


## Min and max right-aligned, each with room on its left so the two never touch.
static func _axis_row(axis: String, lo: float, hi: float) -> String:
	return ("[cell][color=%s]%s[/color][/cell][cell padding=%d,0,0,0][right]%s[/right][/cell]"
		+ "[cell padding=%d,0,0,0][right]%s[/right][/cell]") % [AXIS_COLOR, axis,
		_COLUMN_GAP_PX, ReadoutFormat.grouped(lo), _COLUMN_GAP_PX, ReadoutFormat.grouped(hi)]


# ── Ground ──────────────────────────────────────────────────────────────────────────────────────

## What the game thinks we stand on, and HOW it decided — SurfaceProbe.explain_under's own answer,
## the one the footsteps use (PlayerClient keeps it), so what you read is what you hear. `via`:
##   objet    a ray hit something with a material — the detail names it
##   terrain  a ray hit terrain collision (server-side only, so rare on a client)
##   planete  nothing was hit, so the planet's biome answered (the normal outdoor case)
##   aucun    nothing answered at all
static func surface_lines(info: Dictionary, body: Node) -> PackedStringArray:
	if info.is_empty():
		return ["surface --"]
	var family : String = String(info.get("family", ""))
	# Whether a sample exists is half the answer: an unmapped family and a mapped one with no file
	# sound identical in game (both play the error marker) and are two different things to fix.
	var mapped : String = ""
	if is_instance_valid(body) and "sfx_footsteps" in body and body.sfx_footsteps != null and family != "":
		mapped = "  (son : oui)" if body.sfx_footsteps.has(StringName(family)) else "  (son : MANQUANT)"
	return [
		"surface: %s%s" % [family if family != "" else "INCONNUE", mapped],
		ReadoutFormat.escape("via %s : %s" % [String(info.get("source", "?")), String(info.get("detail", ""))]),
	]
