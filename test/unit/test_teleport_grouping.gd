extends GutTest
## TeleportCatalog.grouped: the teleporter's destinations by heading — the stations first, the POI types
## in alphabetical order, the computed points last — each heading in natural order (F0003 before F0004,
## city_2 before city_11). The list came in file order, which read as no order at all (2026-10-13).


func _dest(label: String, group: String) -> TeleportDestination:
	var d := TeleportDestination.new(label, "tarsis_3")
	d.group = group
	return d


func test_headings_and_their_order() -> void:
	var list: Array[TeleportDestination] = [
		_dest("Low orbit", TeleportCatalog.GROUP_COMPUTED),
		_dest("M0042", TeleportCatalog.POI_TYPE_GROUPS["mining village"]),
		_dest("major_railway_city_11", TeleportCatalog.POI_TYPE_GROUPS["railway city"]),
		_dest("F0005", TeleportCatalog.POI_TYPE_GROUPS["factory village"]),
		_dest("Palaka-Pital", TeleportCatalog.GROUP_STATIONS),
		_dest("major_railway_city_2", TeleportCatalog.POI_TYPE_GROUPS["railway city"]),
		_dest("F0003", TeleportCatalog.POI_TYPE_GROUPS["factory village"]),
		_dest("Lone", ""),
	]
	var groups: Array = TeleportCatalog.grouped(list)
	var headings: PackedStringArray = []
	for g: Array in groups:
		headings.append(str(g[0]))
	assert_eq(headings, PackedStringArray([TeleportCatalog.GROUP_STATIONS, TeleportCatalog.GROUP_POI,
		TeleportCatalog.POI_TYPE_GROUPS["factory village"], TeleportCatalog.POI_TYPE_GROUPS["mining village"],
		TeleportCatalog.POI_TYPE_GROUPS["railway city"], TeleportCatalog.GROUP_COMPUTED]),
		"stations, the POI types alphabetically (untyped under the POI heading), computed points last")
	var factory: Array = groups[2][1]
	assert_eq((factory[0] as TeleportDestination).label, "F0003", "alphabetical inside a heading")
	var railway: Array = groups[4][1]
	assert_eq((railway[0] as TeleportDestination).label, "major_railway_city_2", "natural order: 2 before 11")


func test_the_bodies_are_marked_planet_moon_or_giant() -> void:
	var marks: Dictionary = {}
	for row: Dictionary in TeleportCatalog.bodies("tarsis"):
		marks[row["key"]] = TeleportCatalog.body_mark(row)
	assert_eq(marks.get("tarsis_3"), TeleportCatalog.MARK_PLANET, "SandBox: a planet")
	assert_eq(marks.get("tarsis_3_1"), TeleportCatalog.MARK_MOON, "Korax: a moon")
	assert_eq(marks.get("tarsis_5"), TeleportCatalog.MARK_GIANT, "Tarsis V: a gas giant")
	assert_eq(marks.get("tarsis_6"), TeleportCatalog.MARK_GIANT, "Tarsis VI: an ice giant")


func test_the_list_opens_on_the_body_with_poi() -> void:
	var rows: Array[Dictionary] = TeleportCatalog.bodies("tarsis")
	assert_eq(str(rows[TeleportCatalog.preferred_body_index(rows)]["key"]), "tarsis_3",
			"SandBox - Tarsis III, the one body with surveyed POI")


func test_the_screen_sends_the_destination_picked_in_its_tree() -> void:
	# The real path of the TELEPORT button: the screen built, the system loaded, a POI picked in the tree.
	# Switching the list to a Tree left an ItemList call there, and the button failed on every click.
	var screen := TeleporterUI.new()
	add_child_autofree(screen)
	screen.load_systems(TeleportCatalog.systems(), "tarsis")
	assert_eq(screen._body_key, "tarsis_3", "opened on the body with POI")
	var heading: TreeItem = screen._dest_list.get_root().get_first_child()
	while heading != null and (heading.get_child_count() == 0 or heading.get_child(0).get_metadata(0) == null \
			or (heading.get_child(0).get_metadata(0) as TeleportDestination).is_station()):
		heading = heading.get_next()
	assert_not_null(heading, "a heading of POI or points")
	var row: TreeItem = heading.get_child(0)
	row.select(0)
	var sent: TeleportDestination = screen._typed_destination()
	assert_not_null(sent, "the button sends something")
	assert_eq(sent.label, (row.get_metadata(0) as TeleportDestination).label, "named after the row picked")
