extends Node
## Throwaway probe: places a row of vehicle lifts along the top edge of a sloped cliff of tarsis_3.
##
## The lift's frame (vehicle_lift_gizmo.gd): origin on the edge, +Z over the drop, the guide stands
## guide_z_offset further out and the platform runs straight down it for descent_depth. On a SLOPED
## face the guide must stand past the foot of the slope, or the platform would ride into it: the
## offset is the smallest one whose lower-landing footprint (22 x 8 m) is clear ground at the foot,
## with no part of the slope above it.
##
## CLIFF_LATLON="lat,lon" (a point at the foot, facing the cliff), CLIFF_COUNT (6), CLIFF_SPACING (80).
## Output: user://cliff_lifts_probe.txt and user://cliff_lifts.json (startup_items entries).

const PLANET_SCENE := "res://scenes/systems/tarsis/tarsis_3.tscn"
## Height of the lift's origin above the ground it stands on (the first lift's, hand-placed).
const ORIGIN_ABOVE_GROUND := 0.74
## Lower landing footprint in the lift frame: x half-width, z from/to past the guide (lower_landing).
const FOOT_HALF_X := 11.1
const FOOT_Z0 := -0.5
const FOOT_Z1 := 8.0
## Height spread allowed over the lower landing footprint (m): its 5 m foundation takes up a slope.
const FOOT_TOLERANCE := 4.0

static var _out: FileAccess = null
var data: PlanetData


func say(t: String) -> void:
	if _out == null:
		_out = FileAccess.open("user://cliff_lifts_probe.txt", FileAccess.WRITE)
	_out.store_line(t)
	_out.flush()
	print(t)


func _ready() -> void:
	var ll := OS.get_environment("CLIFF_LATLON").split(",")
	var count := int(OS.get_environment("CLIFF_COUNT")) if OS.get_environment("CLIFF_COUNT") != "" else 6
	var spacing := float(OS.get_environment("CLIFF_SPACING")) if OS.get_environment("CLIFF_SPACING") != "" else 80.0
	var lat := deg_to_rad(float(ll[0]))
	var lon := deg_to_rad(float(ll[1]))
	var body: Node = (load(PLANET_SCENE) as PackedScene).instantiate()
	data = body.get("planet_data")
	data.apply_chunk_manifest()
	data.remote_source = RemoteTileSource.for_planet(data.planet_name)
	data.warm_mountains()
	data.set_crack_exclusions(PlanetTerrain.poi_crack_exclusions(data.planet_name))

	var foot := Vector3(cos(lat) * cos(lon), sin(lat), -cos(lat) * sin(lon)).normalized()
	var foot_h := _h(foot)
	# Uphill: the steepest rise from the foot, measured over the first 100 m.
	var uphill := Vector3.ZERO
	var best_rise := -INF
	for b in range(0, 360, 2):
		var t := _tangent_at_bearing(foot, b)
		var rise := _h(_move(foot, t * 100.0)) - foot_h
		if rise > best_rise:
			best_rise = rise
			uphill = t
	say("PROBE foot %.2f m, uphill rise %.1f m over 100 m" % [foot_h, best_rise])
	var along := foot.cross(uphill).normalized()  # the cliff's run, tangent

	# The edge point straight up the slope from the foot, then the row centred on it.
	var centre := _edge_from(foot, uphill)
	var entries := []
	var edges := []
	for k in count:
		var s := (float(k) - (count - 1) * 0.5) * spacing
		# A point at the foot under this lift, then up the local steepest slope to the edge.
		var start := _move(foot, along * s)
		var up_k := _steepest(start, uphill)
		var edge := _edge_from(start, up_k)
		edges.append(edge)
	for k in count:
		var edge: Vector3 = edges[k]
		# Local edge direction from the neighbours, outward (+Z) = downhill, perpendicular to it.
		var e0: Vector3 = edges[maxi(k - 1, 0)]
		var e1: Vector3 = edges[mini(k + 1, count - 1)]
		var tang := ((e1 - e0) - edge * (e1 - e0).dot(edge)).normalized()
		var z := edge.cross(tang).normalized()
		if (_h(_move(edge, z * 30.0)) > _h(edge)):
			z = -z
		var top_h := _h(edge)
		# Smallest guide offset with a clear, level footprint at the foot.
		var offset := -1.0
		var low_h := 0.0
		var x_axis := edge.cross(z).normalized()
		for d in range(0, 800):
			var lo := INF
			var hi := -INF
			for xi in 5:
				var x := lerpf(-FOOT_HALF_X, FOOT_HALF_X, xi / 4.0)
				var zz := FOOT_Z0
				while zz <= FOOT_Z1:
					var h := _h(_move(edge, z * (d + zz) + x_axis * x))
					lo = minf(lo, h)
					hi = maxf(hi, h)
					zz += 1.0
			if hi - lo <= FOOT_TOLERANCE and hi < top_h - 20.0:
				offset = d
				low_h = hi
				break
		var basis := Basis(x_axis, edge, z).orthonormalized()
		var pos := edge * (data.radius + top_h + ORIGIN_ABOVE_GROUND)
		var e := basis.get_euler()
		var descent := top_h - low_h
		var spacing_prev := (edge - (edges[k - 1] as Vector3)).length() * data.radius if k > 0 else 0.0
		say("PROBE lift %d: edge %.1f m, guide_z_offset %.0f m, foot %.1f m -> descent %.1f m, %.1f m from the previous"
				% [k + 1, top_h, offset, low_h, descent, spacing_prev])
		entries.append({
			"object_data": {
				"parent_id": "_planet_SandBox",
				"position": {"x": snappedf(pos.x, 0.001), "y": snappedf(pos.y, 0.001), "z": snappedf(pos.z, 0.001)},
				"rotation": {"x": snappedf(e.x, 0.000001), "y": snappedf(e.y, 0.000001), "z": snappedf(e.z, 0.000001)},
				"scenename": "scenes/_universe/structures/industrial/vehicle_lift/vehicle_lift.tscn",
				"name": "Vehicle Lift Cliff %d" % (k + 1),
				"guide_z_offset": float(offset),
				"platform_progress_ratio": 0.0,
				"target_ratio": 0.0,
				"descent_depth": snappedf(descent, 0.1),
				"max_speed": 5.0,
				"acceleration": 1.0,
				"is_platformsystem_spawned": false,
				"is_moving": false,
			},
			"object_type": "vehicle_lift",
			"object_uuid": PropSpawn.stable_uuid("tarsis_3|cliff_lift|%d" % (k + 1)),
		})
	var f := FileAccess.open("user://cliff_lifts.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(entries, "    "))
	f.close()
	say("PROBE wrote %d entries to %s" % [entries.size(), ProjectSettings.globalize_path("user://cliff_lifts.json")])
	body.free()
	get_tree().quit()


## Walk up the slope from [param from] along [param up] in 1 m steps to the brink: the first point
## from which the next 2 m rise less than 1 m. Returns its direction.
func _edge_from(from: Vector3, up: Vector3) -> Vector3:
	var p := from
	var climbing := false
	for i in 1500:
		var nxt := _move(p, up * 2.0)
		var rise := _h(nxt) - _h(p)
		if rise >= 1.0:
			climbing = true
		elif climbing:
			return p
		p = _move(p, up * 1.0)
	push_warning("no edge found")
	return p


## The steepest uphill tangent at [param at] within 40° of [param hint].
func _steepest(at: Vector3, hint: Vector3) -> Vector3:
	var best := hint
	var best_rise := -INF
	var side := at.cross(hint).normalized()
	for a in range(-40, 41, 4):
		var t := (hint * cos(deg_to_rad(a)) + side * sin(deg_to_rad(a))).normalized()
		var probe := _move(at, t * 100.0)
		var rise := _h(probe) - _h(at)
		if rise > best_rise:
			best_rise = rise
			best = t
	return best


func _tangent_at_bearing(dir: Vector3, bearing_deg: float) -> Vector3:
	var east := Vector3.UP.cross(dir).normalized()
	var north := dir.cross(east).normalized()
	return east * sin(deg_to_rad(bearing_deg)) + north * cos(deg_to_rad(bearing_deg))


func _move(dir: Vector3, offset_m: Vector3) -> Vector3:
	return (dir * data.radius + offset_m).normalized()


func _h(dir: Vector3) -> float:
	return data.crack_aware_surface_dist(dir) - data.radius
