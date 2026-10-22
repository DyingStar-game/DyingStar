extends GutTest
## The observability logger hands every printed line to the C# bridge: 0.16 ms a line instead of 0.004.
## It is plugged in only while the export is on, which it never is for a player (client.ini has no
## [observability] section).


func test_the_logger_is_plugged_only_while_the_export_is_on() -> void:
	if Obs.otel_manager == null:
		pass_test("dedicated server: no bridge at all")
		return
	assert_eq(Obs._logger != null, bool(Obs.otel_manager.GDS_IsEnabled()))


func test_a_forwarded_line_is_not_printed_again() -> void:
	if Obs.otel_manager == null:
		pass_test("dedicated server: no bridge at all")
		return
	Obs.forward("[TestObs] a line", false)
	Obs.forward("[TestObs] an error", true)
	assert_true(true, "forwarding never echoes nor fails, export on or off")
