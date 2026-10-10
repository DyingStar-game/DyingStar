extends GutTest


func test_no_build_id_outside_an_export() -> void:
	# res://build_id.json only exists inside an exported pack.
	assert_false(FileAccess.file_exists(BuildInfo.PATH))
	assert_eq(BuildInfo.build_id(), "")


func test_make_build_id_is_date_time_random() -> void:
	var re := RegEx.create_from_string("^\\d{8}-\\d{4}-\\d{6}$")
	var id := BuildInfo.make_build_id()
	assert_not_null(re.search(id), "id %s" % id)
	var today := Time.get_datetime_dict_from_system()
	assert_true(id.begins_with("%04d%02d%02d" % [today.year, today.month, today.day]))
