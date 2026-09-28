extends SceneTree
## Prints the horizonserver seed entry (ds_genericprops/startup_items.json) of every station of a
## system, from its StationSite — so the seed can never drift from what the game computes.
##
##   godot --headless --path . -s res://tools/stations/station_seed.gd -- [system=tarsis]
##
## The pose written is the station's ORBITAL pose at t = 0, in the body's non-rotating frame. It only has to
## be ON the orbit: the server's station body never moves, and what is aboard holds positions relative to
## it; anything that needs where the station REALLY is asks its orbit for the time
## (Server.system_transform_of). Horizon keeps it there (see OrbitalStation for why). Clients place it
## themselves.
##
## The scene is the site's (StationSite.scene). The parent is the body's service name ("_planet_SandBox"),
## taken from its display name ("SandBox - Tarsis III"); Horizon resolves it to the planet's uuid when it
## seeds.


func _init() -> void:
	var system: String = "tarsis"
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("system="):
			system = arg.trim_prefix("system=")
	var entries: Array = []
	for site: StationSite in StationSites.of_system(system):
		var props: Dictionary = SystemScenes.body_properties(system, site.body_key)
		entries.append(seed_entry(site, props))
	print(JSON.stringify(entries, "\t"))
	quit()


## The seed entry of [param site], given its body's saved properties.
static func seed_entry(site: StationSite, body_props: Dictionary) -> Dictionary:
	var orbit: StationOrbit = site.orbit(body_props)
	var at: Vector3 = orbit.position_at(0.0)
	var euler: Vector3 = orbit.attitude_at(0.0).get_euler()
	var service_name: String = str(body_props.get("display_name", site.body_key)).get_slice(" - ", 0)
	return {
		"object_type": "station",
		"object_uuid": site.uuid(),
		"object_data": {
			"name": site.proper_name,
			"parent_id": "_planet_" + service_name,
			"scenename": site.scenename(),
			"position": {"x": at.x, "y": at.y, "z": at.z},
			"rotation": {"x": euler.x, "y": euler.y, "z": euler.z},
		},
	}
