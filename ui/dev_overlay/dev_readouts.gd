class_name DevReadouts
extends RefCounted
## What the debug panel's sections say, as pure functions: data in, lines out. The panel (DevOverlay)
## decides when and where; these only format — so each is tested without a panel or a server.

## The eight winds a direction is named after, clockwise from north.
const COMPASS : PackedStringArray = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
## Under this speed (m/s) the weather readout says "calm" and names no direction.
const CALM_M_S : float = 0.05

## The server border is measured up to this far (m) along the camera; beyond, the readout says "> 30000".
const BORDER_FAR_M : float = 30000.0
## Zones of the same server crossed on the way to the border, at most.
const _BORDER_MAX_HOPS : int = 8
## Past a zone's face before looking for the next zone (m): enough to leave it at 1e11 m in doubles.
const _BORDER_STEP_M : float = 0.01


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
		"%s servers" % _count(cache.value("universe_servers")),
		"%s players" % _count(cache.value("universe_players")),
		planet_time(body),
	]
	out.append_array(where(body))
	out.append(daylight_line(body))
	return out


## The daylight here as a photocell reads it (Planet.daylight_at), in lux, against the photocells'
## default thresholds: to tune them by eye, the value read at the moment a lamp should come on.
static func daylight_line(body: Node3D) -> String:
	var planet : Planet = Planet.of(body) if is_instance_valid(body) else null
	if planet == null:
		return "light: --"
	return daylight_text(planet.daylight_at(body.global_position))


## [param daylight] (0..1) as the readout's text.
static func daylight_text(daylight: float) -> String:
	var tuning: PhotocellTuning = Photocell.DEFAULT_TUNING
	return "light: daylight %.4f (~%.0f lux)  photocell on < %.0f lux, off > %.0f lux" % [daylight,
		PhotocellTuning.lux_of(daylight), tuning.on_below_lux, tuning.off_above_lux]


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


## Where [param body] stands, for a bug report (BugReporter.locate): {"world": its place in the system
## (m), "planet": the body it belongs to with its latitude, longitude and elevation above the reference
## sphere, "frame": the node carrying it}. A key with nothing to say is left out: no planet in deep
## space, nothing at all without a body. Plain short texts in English, the QA team's to read; untyped,
## so a body freed meanwhile is told from a live one instead of being an error.
static func coordinates(body: Variant) -> Dictionary:
	if not is_instance_valid(body) or not (body is Node3D):
		return {}
	var here : Vector3 = (body as Node3D).global_position
	var out : Dictionary = {"world": "%.1f, %.1f, %.1f" % [here.x, here.y, here.z]}
	var planet : Planet = Planet.of(body)
	if planet != null and planet.planet_data != null:
		var lonlat : Vector2 = planet.lonlat_of(here)
		out["planet"] = "%s, %.5f° %s, %.5f° %s, alt %d m" % [planet.name, absf(lonlat.y),
			"N" if lonlat.y >= 0.0 else "S", absf(lonlat.x), "E" if lonlat.x >= 0.0 else "W",
			roundi(planet.elevation_of(here))]
	elif planet != null:
		out["planet"] = str(planet.name)
	var parent : Node = (body as Node3D).get_parent()
	if parent != null:
		out["frame"] = str(parent.name)
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

static func server_lines(cache: ServerInfoCache, body: Node3D = null) -> PackedStringArray:
	var tps : Variant = cache.value("tps")
	return [
		"server name: %s" % ReadoutFormat.escape(str(cache.value("server_name", "-"))),
		ReadoutFormat.rated(float(tps), 30.0, "TPS") if tps != null else "- TPS",
		"%s players" % _count(cache.value("server_players")),
		"%s objects" % _count(cache.value("server_objects")),
		"%s scenes" % _count(cache.value("server_scenes")),
		"%s active scenes" % _count(cache.value("server_active_scenes")),
		border_line(body, cache),
	]


## A server count as an integer — JSON hands every number over as a float ("1234.0") — or "-" until
## the server has sent it.
static func _count(v: Variant) -> String:
	return "-" if v == null else str(int(v))


## The server border straight ahead of the camera. Zone bounds are in the WORLD's coordinates (see
## server.gd server_zones): planet-local on a planet — where the server keeps the planet at its origin,
## unspun, while here it spins, hence the conversion — universe coordinates in space.
static func border_line(body: Node3D, cache: ServerInfoCache) -> String:
	if not is_instance_valid(body) or not body.is_inside_tree():
		return "frontière : --"
	var camera : Camera3D = body.get_viewport().get_camera_3d()
	var zones : Array = cache.value("zones", [])
	if camera == null or zones.is_empty():
		return "frontière : --"
	var pos : Vector3 = body.global_position
	var dir : Vector3 = -camera.global_basis.z
	var planet : Planet = Planet.of(body)
	var planet_uuid : String = ""
	if planet != null:
		planet_uuid = str(planet.uuid)
		pos = planet.global_transform.affine_inverse() * pos
		dir = planet.global_basis.orthonormalized().inverse() * dir
	return border_text(border_distance(zones, planet_uuid, pos, dir.normalized()))


## Metres from [param pos] to the border of the zones in [param zones] along [param dir] (unit), in the
## world of [param planet_uuid] ("" = space). A zone of the same server next to ours is no border: the
## walk goes on through it. INF for a whole world, NAN when [param pos] is in none of our zones (a hand
## over in progress), and anything past BORDER_FAR_M is not measured further.
static func border_distance(zones: Array, planet_uuid: String, pos: Vector3, dir: Vector3) -> float:
	var travelled : float = 0.0
	var p : Vector3 = pos
	for _hop in _BORDER_MAX_HOPS:
		var bounds : Variant = false  # false = no zone holds p
		for zone in zones:
			if _zone_in_world(zone, planet_uuid) and _zone_holds(zone, p):
				bounds = zone.get("bounds")
				break
		if bounds is bool:
			return NAN if travelled == 0.0 else travelled
		if bounds == null:
			return INF
		var t : float = _exit_distance(bounds, p, dir)
		travelled += t
		if travelled > BORDER_FAR_M:
			return travelled
		p += dir * (t + _BORDER_STEP_M)
	return travelled


static func border_text(distance: float) -> String:
	if is_nan(distance):
		return "frontière : hors zone"
	if distance > BORDER_FAR_M:
		return "frontière : > %d mètres" % int(BORDER_FAR_M)
	return "frontière : %.2f mètres" % distance


## Same world test as server.gd _zone_contains_node.
static func _zone_in_world(zone: Dictionary, planet_uuid: String) -> bool:
	match str(zone.get("world", "")):
		"space":
			return planet_uuid == ""
		"planet":
			return planet_uuid != "" and planet_uuid == str(zone.get("planet_uuid", ""))
	return false


static func _zone_holds(zone: Dictionary, p: Vector3) -> bool:
	var b : Variant = zone.get("bounds")
	if b == null:
		return true
	return p.x >= b["min_x"] and p.x <= b["max_x"] and p.y >= b["min_y"] and p.y <= b["max_y"] \
			and p.z >= b["min_z"] and p.z <= b["max_z"]


## Where a ray from inside the box leaves it: the nearest of the planes it heads towards.
static func _exit_distance(b: Dictionary, p: Vector3, dir: Vector3) -> float:
	var lo : Vector3 = Vector3(b["min_x"], b["min_y"], b["min_z"])
	var hi : Vector3 = Vector3(b["max_x"], b["max_y"], b["max_z"])
	var t : float = INF
	for axis in 3:
		if dir[axis] > 0.0:
			t = minf(t, (hi[axis] - p[axis]) / dir[axis])
		elif dir[axis] < 0.0:
			t = minf(t, (lo[axis] - p[axis]) / dir[axis])
	return maxf(t, 0.0)


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


# ── Weather ─────────────────────────────────────────────────────

## The weather where [param body] stands, read through the door everything else uses
## (Planet.weather_at): what you read is what moves the dust and sounds the wind. Under the wind, the
## compass bearing the camera looks along, to tell where the wind comes from without a map.
static func weather_lines(body: Node3D) -> PackedStringArray:
	var planet : Planet = Planet.of(body) if is_instance_valid(body) else null
	if planet == null:
		return ["weather: space"]
	var out : PackedStringArray = weather_lines_of(planet.weather_at(body.global_position))
	var bearing : float = camera_heading(body, planet)
	if not is_nan(bearing):
		out.insert(1, facing_text(bearing))
	return out


## What the compass dial draws (WeatherCompass): {heading_deg, wind_m_s, wind_from_deg}, from the same
## reading as the lines above; {} off a planet, without air, or with no camera.
static func compass_state(body: Node3D) -> Dictionary:
	var planet : Planet = Planet.of(body) if is_instance_valid(body) else null
	if planet == null:
		return {}
	var sample : Dictionary = planet.weather_at(body.global_position)
	var bearing : float = camera_heading(body, planet)
	if sample.is_empty() or is_nan(bearing):
		return {}
	var east : float = float(sample.get("wind_east_m_s", 0.0))
	var north : float = float(sample.get("wind_north_m_s", 0.0))
	return {"heading_deg": maxf(bearing, 0.0), "wind_m_s": _wind_speed(sample),
		"wind_from_deg": fposmod(float(sample.get("wind_from_deg", rad_to_deg(atan2(-east, -north)))), 360.0)}


## The compass bearing the camera looks along from where [param body] stands on [param planet]; -1 looking
## straight up or down, NAN without a camera.
static func camera_heading(body: Node3D, planet: Planet) -> float:
	var camera : Camera3D = body.get_viewport().get_camera_3d() if body.is_inside_tree() else null
	if camera == null:
		return NAN
	var to_local : Basis = planet.global_basis.orthonormalized().inverse()
	return heading_of(planet.local_dir_of(body.global_position), to_local * -camera.global_basis.z)


## The compass bearing (degrees clockwise from north) of [param forward] seen from the ground at
## [param up], both in the planet's own frame (Planet.local_axes); -1 when looking straight up or down.
static func heading_of(up: Vector3, forward: Vector3) -> float:
	var axes : Array = Planet.local_axes(up)
	var level : Vector3 = forward - up.normalized() * forward.dot(up.normalized())
	if level.length_squared() < 1e-8:
		return -1.0
	return fposmod(rad_to_deg(atan2(level.dot(axes[0]), level.dot(axes[1]))), 360.0)


## [param bearing] as the readout's line: "facing NE (045°)", or the vertical when there is none.
static func facing_text(bearing: float) -> String:
	if bearing < 0.0:
		return "facing straight up or down"
	return "facing %s (%03d°)" % [compass(bearing), roundi(bearing) % 360]


## [param sample] (WeatherSource's keys, plus what the source adds) as the readout's lines. A source
## gives what it knows: a line is written only for the keys it carries.
##   wind         speed in m/s and km/h, and where it blows FROM (the eight winds, and degrees)
##   sand         the speed at which the ground's grains lift, and whether the wind is over it now
##   temperature  in °C and K
##   pressure     in hPa, and what the passing systems add or take
##   dust         optical depth over the place, and how far one sees through it
##   air          density, what the wind's push and sound are worked out from
##   band / here  the wind band of the latitude, and the local phenomena felt on the spot
static func weather_lines_of(sample: Dictionary) -> PackedStringArray:
	if sample.is_empty():
		return ["weather: no air"]
	var out : PackedStringArray = [wind_text(sample)]
	var speed : float = _wind_speed(sample)
	if sample.has("lift_threshold_m_s"):
		var threshold : float = float(sample["lift_threshold_m_s"])
		out.append("sand lifts over %.1f m/s: %s" % [threshold, "lifting" if speed > threshold else "not lifting"])
	if sample.has("temperature_k"):
		var kelvin : float = float(sample["temperature_k"])
		out.append("temperature %.1f °C (%.1f K)" % [kelvin - 273.15, kelvin])
	if sample.has("pressure_pa"):
		var pressure : String = "pressure %.0f hPa" % (float(sample["pressure_pa"]) / 100.0)
		if sample.has("pressure_anomaly_pa"):
			pressure += " (%+.1f)" % (float(sample["pressure_anomaly_pa"]) / 100.0)
		out.append(pressure)
	if sample.has("dust_tau"):
		var dust : String = "dust tau %.2f" % float(sample["dust_tau"])
		if sample.has("visibility_m"):
			dust += "  visibility %.1f km" % (float(sample["visibility_m"]) / 1000.0)
		out.append(dust)
	if sample.has("air_density_kg_m3"):
		out.append("air %.3f kg/m³" % float(sample["air_density_kg_m3"]))
	if sample.has("band"):
		out.append(ReadoutFormat.escape("band: %s" % String(sample["band"])))
	var here : PackedStringArray = []
	for name: Variant in sample.get("phenomena", []):
		here.append(String(name))
	if not here.is_empty():
		out.append(ReadoutFormat.escape("here: %s" % ", ".join(here)))
	return out


## The wind of [param sample] as one line: "wind 25.0 m/s (90 km/h) from NE (045°)", or "wind calm".
static func wind_text(sample: Dictionary) -> String:
	var speed : float = _wind_speed(sample)
	if speed < CALM_M_S:
		return "wind calm"
	var east : float = float(sample.get("wind_east_m_s", 0.0))
	var north : float = float(sample.get("wind_north_m_s", 0.0))
	# Where it blows FROM, clockwise from north: the source's own figure, or the opposite of where it goes.
	var from_deg : float = fposmod(float(sample.get("wind_from_deg", rad_to_deg(atan2(-east, -north)))), 360.0)
	return "wind %.1f m/s (%.0f km/h) from %s (%03d°)" % [speed, speed * 3.6, compass(from_deg), roundi(from_deg) % 360]


## The one of the eight winds nearest to [param degrees] (clockwise from north).
static func compass(degrees: float) -> String:
	return COMPASS[roundi(fposmod(degrees, 360.0) / 45.0) % COMPASS.size()]


static func _wind_speed(sample: Dictionary) -> float:
	if sample.has("wind_speed_m_s"):
		return float(sample["wind_speed_m_s"])
	return Vector2(float(sample.get("wind_east_m_s", 0.0)), float(sample.get("wind_north_m_s", 0.0))).length()


# ── Music ───────────────────────────────────────────────────────────────────────────────────────

## What plays and WHY — MusicDirector.debug_state's own answer, so what you read is what you hear:
##   track     the file, and how far into it; or the silence, and how long before the next one
##   playlist  the .tres it comes from
##   case      the line of music_table.tres that won (or the zone's own playlist, or no rule at all)
##   where     all the player's situation is made of — a rule can only match what is listed here
##   next      the playlist about to take over, while the new situation has not held long enough yet
static func music_lines(state: Dictionary) -> PackedStringArray:
	if state.is_empty():
		return ["music --"]
	var track : String = String(state.get("track", ""))
	var gap_s : float = float(state.get("gap_left_s", -1.0))
	var playing : String = "(silence)"
	if track != "":
		playing = "%s  %s / %s" % [track, _minutes(float(state.get("position_s", 0.0))),
			_minutes(float(state.get("length_s", 0.0)))]
	elif gap_s >= 0.0:
		playing = "(silence, next track in %d s)" % ceili(gap_s)
	var playlist : String = String(state.get("playlist", ""))
	var out : PackedStringArray = [
		ReadoutFormat.escape("track: %s" % playing),
		ReadoutFormat.escape("playlist: %s" % (playlist if playlist != "" else "(none)")),
		ReadoutFormat.escape("case: %s" % String(state.get("why", "?"))),
		ReadoutFormat.escape("where: %s" % String(state.get("where", "?"))),
	]
	if state.has("pending"):
		var pending : String = String(state["pending"])
		out.append(ReadoutFormat.escape("next: %s" % (pending if pending != "" else "(silence)")))
	return out


static func _minutes(seconds: float) -> String:
	var whole : int = int(seconds)
	return "%d:%02d" % [whole / 60, whole % 60]
