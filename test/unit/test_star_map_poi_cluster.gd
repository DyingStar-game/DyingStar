extends GutTest
## StarMapPoiCluster: towns whose badges would land on one another are drawn as one marker with their
## number, and come apart as the view comes down. Sixty-two villages of tarsis_3 line one corridor;
## drawn one by one they were a heap nobody could read or click.

const REACH: float = 30.0


func _sizes(groups: Array[PackedInt32Array]) -> Array[int]:
	var out: Array[int] = []
	for members: PackedInt32Array in groups:
		out.append(members.size())
	return out


## Four towns on a line, [param step] pixels apart: the same ground seen from higher or lower.
func _line(step: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(0, 0), Vector2(step, 0), Vector2(2 * step, 0), Vector2(3 * step, 0)])


func test_towns_far_apart_stay_on_their_own() -> void:
	var groups := StarMapPoiCluster.group(PackedInt32Array([0, 1, 2]),
			PackedVector2Array([Vector2(0, 0), Vector2(200, 0), Vector2(0, 200)]), REACH)
	assert_eq(_sizes(groups), [1, 1, 1] as Array[int])


func test_towns_on_the_same_pixels_become_one_marker_with_their_number() -> void:
	var groups := StarMapPoiCluster.group(PackedInt32Array([4, 7, 9, 12]),
			PackedVector2Array([Vector2(0, 0), Vector2(10, 5), Vector2(300, 0), Vector2(5, 10)]), REACH)
	assert_eq(groups.size(), 2, "one group and the town that stands apart")
	assert_eq(groups[0], PackedInt32Array([4, 7, 12]), "the towns' own indices, the first naming the group")
	assert_eq(groups[1], PackedInt32Array([9]))


func test_coming_down_takes_the_groups_apart_a_few_at_a_time() -> void:
	var towns := PackedInt32Array([0, 1, 2, 3])
	assert_eq(_sizes(StarMapPoiCluster.group(towns, _line(8.0), REACH)), [4] as Array[int],
		"from high up, one marker")
	assert_eq(_sizes(StarMapPoiCluster.group(towns, _line(20.0), REACH)), [2, 2] as Array[int],
		"lower, two smaller ones")
	assert_eq(_sizes(StarMapPoiCluster.group(towns, _line(40.0), REACH)), [1, 1, 1, 1] as Array[int],
		"lower still, the towns themselves")


func test_the_selected_town_is_never_folded_into_a_group() -> void:
	var groups := StarMapPoiCluster.group(PackedInt32Array([0, 1, 2]),
			PackedVector2Array([Vector2(0, 0), Vector2(5, 0), Vector2(10, 0)]), REACH, PackedInt32Array([1]))
	assert_eq(groups.size(), 2)
	assert_eq(groups[0], PackedInt32Array([0, 2]), "its neighbours still group")
	assert_eq(groups[1], PackedInt32Array([1]), "the one asked for stays a town")


func test_a_selected_town_does_not_gather_its_neighbours_either() -> void:
	var groups := StarMapPoiCluster.group(PackedInt32Array([0, 1]),
			PackedVector2Array([Vector2(0, 0), Vector2(5, 0)]), REACH, PackedInt32Array([0]))
	assert_eq(_sizes(groups), [1, 1] as Array[int])


func test_a_group_holds_a_little_past_the_distance_it_formed_at() -> void:
	var towns := PackedInt32Array([0, 1])
	var just_outside := PackedVector2Array([Vector2(0, 0), Vector2(REACH + 4.0, 0)])
	assert_eq(_sizes(StarMapPoiCluster.group(towns, just_outside, REACH)), [1, 1] as Array[int],
		"two towns that were apart stay apart")
	var together := StarMapPoiCluster.memory(StarMapPoiCluster.group(towns,
			PackedVector2Array([Vector2(0, 0), Vector2(REACH - 4.0, 0)]), REACH))
	assert_eq(together, {0: 0, 1: 0}, "remembered as index → the group's first member")
	assert_eq(_sizes(StarMapPoiCluster.group(towns, just_outside, REACH, PackedInt32Array(), together)),
		[2] as Array[int], "the same two, grouped a frame ago, do not split on the threshold")
	var well_outside := PackedVector2Array([Vector2(0, 0), Vector2(REACH / StarMapPoiCluster.KEEP + 1.0, 0)])
	assert_eq(_sizes(StarMapPoiCluster.group(towns, well_outside, REACH, PackedInt32Array(), together)),
		[1, 1] as Array[int], "but they do once clearly apart")


func test_the_group_picture_is_the_waypoint() -> void:
	var picture: Texture2D = StarMapPoiLayer.ICONS.cluster_picture()
	assert_not_null(picture)
	assert_eq(picture.resource_path, "res://assets/textures/poi/waypoint.png")
