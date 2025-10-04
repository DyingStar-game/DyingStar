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

func _log_message(message: String, error: bool) -> void:
	if message.contains("OBS"):
		return
	if error:
		Obs.logs_error("",message);
	else :
		Obs.logs_info("", message)
