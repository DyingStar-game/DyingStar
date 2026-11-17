extends GutTest
## ClientPerf.redacted_args: the boot dump prints the command line, never the player's JWT in it.


func test_the_token_is_masked() -> void:
	var args := PackedStringArray(["--server=preprod", "--token=eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxIn0.sig"])
	assert_eq(ClientPerf.redacted_args(args), PackedStringArray(["--server=preprod", "--token=xxxxx"]))


func test_other_secret_flags_are_masked_too() -> void:
	var args := PackedStringArray(["--refresh-token=abc", "--client-secret=def", "--Password=ghi"])
	assert_eq(ClientPerf.redacted_args(args),
			PackedStringArray(["--refresh-token=xxxxx", "--client-secret=xxxxx", "--Password=xxxxx"]))


func test_ordinary_flags_are_left_alone() -> void:
	var args := PackedStringArray(["--perf-verbose", "--token", "res://main.tscn", "--name=token"])
	assert_eq(ClientPerf.redacted_args(args), args)
