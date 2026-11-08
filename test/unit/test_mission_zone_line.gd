extends GutTest

## A mission's zone reads by its POI's name when the mission service gives it ("M0001"), by its id
## otherwise (playtest 2026-11-08: the kiosk showed "Point of interest fd398f99-...").
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_mission_zone_line.gd

const POI := "fd398f99-7bba-42d0-b08b-3631314a8add"


func test_a_named_poi_reads_by_its_name() -> void:
	var line := ServiceTypes.zone_line({"kind": "poi", "poiId": POI, "poiName": "M0001"})
	assert_string_contains(line, "M0001")
	assert_false(line.contains(POI), "no id when there is a name")


func test_an_unnamed_poi_still_reads_by_its_id() -> void:
	assert_string_contains(ServiceTypes.zone_line({"kind": "poi", "poiId": POI}), POI)
