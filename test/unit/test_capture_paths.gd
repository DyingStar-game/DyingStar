extends GutTest
## CapturePaths: where F7 screenshots and F6 recordings land, and what they are called.


func test_stamp_is_a_valid_file_name() -> void:
	var s: String = CapturePaths.stamp()
	assert_false(s.contains(":"), "Windows refuses ':' in a file name")
	assert_true(s.is_valid_filename(), "usable as-is")


func test_screenshots_live_under_the_game_folder() -> void:
	# From the editor (where the tests run) the game folder is the project folder.
	var dir: String = CapturePaths.screenshots_dir()
	assert_eq(dir, CapturePaths.game_dir().path_join("screenshots"), "<game>/screenshots")
	assert_true(DirAccess.dir_exists_absolute(dir), "created on demand")


func test_recordings_go_in_a_sub_folder_of_the_screenshots() -> void:
	var dir: String = CapturePaths.videos_dir()
	assert_eq(dir, CapturePaths.screenshots_dir().path_join("records"), "<game>/screenshots/records")
	assert_true(DirAccess.dir_exists_absolute(dir), "created on demand")


func test_benchmark_reports_live_beside_the_screenshots() -> void:
	var dir: String = CapturePaths.benchmarks_dir()
	assert_eq(dir, CapturePaths.game_dir().path_join("benchmarks"), "<game>/benchmarks")
	assert_true(DirAccess.dir_exists_absolute(dir), "created on demand")
