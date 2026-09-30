class_name MusicPoi
extends RefCounted

## Which point of interest a position on the ground belongs to.
##
## Read from the same QGIS export as the chart (StarMapPoi), not from the POI nodes of the planet
## scene: those are rebuilt by hand from the export and lag behind it. Free of nodes on purpose, so it
## is tested without a planet.


## The point of interest of [param pois] whose influence sphere holds the ground direction
## [param dir] (body-fixed unit vector, Planet.local_dir_of), or an empty dictionary.
##
## Spheres nest — a village stands inside the 25 km of its city — so the SMALLEST one holding the
## position wins: the most local answer is the one the player is looking at.
static func containing(pois: Array[Dictionary], dir: Vector3, body_radius_m: float) -> Dictionary:
	var best: Dictionary = {}
	if dir.is_zero_approx():
		return best
	for poi: Dictionary in pois:
		var radius_m: float = float(poi.get("radius_m", 0.0))
		var poi_dir: Vector3 = poi.get("dir", Vector3.ZERO)
		if radius_m <= 0.0 or poi_dir.is_zero_approx():
			continue
		# Distance along the ground: the influence is a disc drawn on the sphere.
		if dir.angle_to(poi_dir) * body_radius_m > radius_m:
			continue
		if best.is_empty() or radius_m < float(best["radius_m"]):
			best = poi
	return best
