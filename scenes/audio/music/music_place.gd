extends RefCounted
## Where the player MusicDirector follows is, for the music: its music zone, a station, the ground of a
## body and the point of interest there. Apart from the autoload, which loads this script when it first
## needs it: named there, Player, Planet and OrbitalStation made the game compile and load most of its
## scripts and scenes at boot, before its first frame (2026-11-19).

## body name → its points of interest, read once (StarMapPoi.load_for parses a file).
static var _pois_by_body: Dictionary = {}


## Fill [param context] with where [param listener] (a Player in the tree) is.
static func read(context: MusicContext, listener: Player) -> void:
	var detector: Area3D = listener.get_node_or_null("AreaDetector") as Area3D
	if detector != null and detector.monitoring:
		var zone: MusicZone = MusicZone.strongest(detector.get_overlapping_areas())
		if zone != null:
			context.zone_tag = zone.tag
			context.zone_playlist = zone.playlist

	context.floating = listener.floating

	var station: OrbitalStation = OrbitalStation.of(listener)
	if station != null:
		var site: StationSite = station.site()
		context.station_id = site.id if site != null else String(station.name)
		return

	var body: Planet = Planet.of(listener)
	var where: Vector3 = listener.global_position
	if body == null or body.planet_data == null or not body.within_ground_reach(where):
		return
	# Near the ground of a body, the ground decides and `floating` is not asked: down here it is only
	# ever true for the dev flight (god mode), and flying over a town is still being in that town.
	# Seen in game: standing on Tarsis 3 after a dev flight, with the EVA music playing.
	context.floating = false
	context.on_ground = true
	context.poi = MusicPoi.containing(
		_pois_of(body.planet_data.planet_name), body.local_dir_of(where), body.planet_data.radius)


static func _pois_of(body_key: String) -> Array[Dictionary]:
	if not _pois_by_body.has(body_key):
		_pois_by_body[body_key] = StarMapPoi.load_for(body_key)
	return _pois_by_body[body_key]
