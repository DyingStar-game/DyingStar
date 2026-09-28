class_name StationSites
extends RefCounted
## The stations of a system, read from its files: scenes/systems/<system>/stations/*.tres. Works on a
## client that has never seen them on the network — the teleporter and the star map list stations
## that are thousands of kilometres out of range.

const STATIONS_DIR := "stations"
const EXTENSIONS: PackedStringArray = [".tres", ".res"]


## Every station of [param system], sorted by file name.
static func of_system(system: String) -> Array[StationSite]:
	var out: Array[StationSite] = []
	var dir_path: String = SystemScenes.system_dir(system).path_join(STATIONS_DIR)
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return out
	var names: PackedStringArray = PackedStringArray()
	for entry: String in dir.get_files():
		# An export turns a .tres into "<name>.tres.remap" (see SystemScenes.file_name_of).
		var file_name: String = SystemScenes.file_name_of(entry, EXTENSIONS)
		if file_name != "":
			names.append(file_name)
	names.sort()
	for file_name: String in names:
		var site: StationSite = load(dir_path.path_join(file_name)) as StationSite
		if site != null:
			out.append(site)
	return out


## The stations orbiting [param body_key] ("tarsis_3").
static func for_body(system: String, body_key: String) -> Array[StationSite]:
	var out: Array[StationSite] = []
	for site: StationSite in of_system(system):
		if site.body_key == body_key:
			out.append(site)
	return out


## The site a station uuid belongs to, or null.
static func by_uuid(system: String, station_uuid: String) -> StationSite:
	for site: StationSite in of_system(system):
		if site.uuid() == station_uuid:
			return site
	return null
