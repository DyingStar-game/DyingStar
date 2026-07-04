class_name CustomLogger
extends Logger
# func _log_error(
# 	function: String,
# 	file: String,
# 	line: int,
# 	code: String,
# 	rationale: String,
# 	editor_notify: bool,
# 	error_type: int,
# 	script_backtraces: Array[ScriptBacktrace]
# 	) -> void:
# 	pass;

# Re-entrancy guard. Obs.logs_*() can itself emit an engine error — e.g. the
# OpenTelemetry C# bridge throws FileNotFoundException when its assemblies are
# missing, and Godot prints that exception as a new error. Without this guard
# that error re-enters _log_message -> Obs.logs_error -> throws -> ... until the
# stack overflows and the editor crashes (silent SIGSEGV, typically on save).
# The "OBS" check below only filters our own print_rich echo, not exception text.
var _in_log := false


func _log_message(message: String, error: bool) -> void:
	if _in_log:
		return
	if message.contains("OBS"):
		return
	_in_log = true
	if error:
		Obs.logs_error("",message);
	else :
		Obs.logs_info("", message)
	_in_log = false
