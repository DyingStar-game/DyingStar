extends RefCounted
## Reuse infrastructure bakes outside volcanoes whose authored spillways
## were removed, without rebuilding a planet-wide railway for a lava test.

static func legacy_matches(stored: String, wanted: String) -> bool:
	var marker := "|vr%d%s|" % [VolcanoRelief.ALGO_VERSION, LavaSettings.runtime_policy]
	return not LavaSettings.authored_flows_enabled and wanted.contains(marker) and stored == wanted.replace(
		marker, "|vr%d|" % VolcanoRelief.ALGO_VERSION)


static func exclusions(data) -> Dictionary:
	var volcanoes: Array[VolcanoRelief.Volcano] = []
	var seen := {}
	for ip in 12:
		for v: VolcanoRelief.Volcano in data.get_chunk_volcanoes(1, ip):
			var key := VolcanoFeatures.key_of(v)
			if not seen.has(key):
				seen[key] = true
				volcanoes.append(v)
	var lines := {}
	for road: Dictionary in data.get_whole_roads():
		for v in volcanoes:
			var hit := GradeGeom.nearest_on_pieces([road], HEALPix.vec2lonlat(v.c), data.radius * PI / 180.0)
			# Include bed skirts, ramps and segment discretisation conservatively.
			if hit.dist_m <= v.rb * (1.0 + v.irr) + 1000.0:
				lines[int(road.get("feature_id", -1))] = true
				break
	return {"lines": lines, "volcanoes": volcanoes}


static func span_affected(span: Dictionary, volcanoes: Array, radius: float) -> bool:
	var middle: Vector3 = span.get("mid_dir", Vector3.ZERO)
	if middle.is_zero_approx():
		return true
	var reach := float(span.get("span_m", 0.0)) * 0.5 + 1000.0
	for v: VolcanoRelief.Volcano in volcanoes:
		if middle.distance_to(v.c) * radius <= v.rb * (1.0 + v.irr) + reach:
			return true
	return false
