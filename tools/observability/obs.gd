extends  Node

var sections :Dictionary= {
	"network" : "blue",
	"audio" : "green"
}

var levels :Dictionary= {
	"trace" : "grey",
	"debug" : "blue",
	"information" : "green",
	"warning" : "yellow",
	"error" : "red",
	"critical" : "purple"
}


## The C# OpenTelemetry bridge — null on the DEDICATED SERVER, where this
## autoload is inert: no bridge, no CustomLogger, every logs_* / metric /
## trace call below returns at once. The server logs to stdout only, which is
## what Loki collects; routing its every print through C# would cost the tick
## (see the note in server/client.gd). An autoload cannot be dropped per
## export preset (a feature override on "autoload/Obs" registers a second,
## bogus autoload instead), so the switch lives here rather than in
## project.godot — which is also why tools/observability/ must stay in the
## server image: for eight months it was excluded from the Docker context and
## every server boot printed "Failed to instantiate an autoload ... obs.gd".
var otel_manager = null
## The engine logger that hands every printed line to the bridge, while it is plugged in.
var _logger: CustomLogger = null


func _ready() -> void:
	if OS.has_feature("dedicated_server"):
		print("[Obs] dedicated server: observability bridge disabled")
		return
	otel_manager = load("res://tools/observability/OpenTelemetryManager.cs").new()
	otel_manager._ready()
	# The logger hands every printed line to the bridge: 0.16 ms a line instead of 0.004, for nothing while
	# the export is off (no [observability] enabled=true in client.ini: every player).
	if otel_manager.GDS_IsEnabled():
		_logger = CustomLogger.new()
		OS.add_logger(_logger)
	Obs.logs_info("engine","Ready for obs")


## Quitting: unplug the logger while the scripts still run. Left in, the engine kept a script object
## until after the scripting was gone -- the same trap as the network monitors that crashed the game on
## quit (Client._exit_tree) -- and it was still handed what the engine printed as it tore down. The bridge
## goes with it (never in the tree, it was leaked at exit).
func _exit_tree() -> void:
	if _logger != null:
		OS.remove_logger(_logger)
		_logger = null
	if otel_manager != null:
		otel_manager.free()
		otel_manager = null
# LOG

func print_colored(level: String, section: String, message: String) -> void:
	var section_color = sections.get(section,"white")
	var level_color = levels.get(level,"white")
	var owner_color = "white"
	if OS.has_feature("dedicated_server"):
		owner_color = "white"
	else :
		owner_color = "brown"
	print_rich(
		"OBS.[color="+section_color+"][b]["+section+\
		"][/b][/color] [color="+level_color+"]"+\
		level+"[/color] [color="+owner_color+"] "+message+" [/color]"
	)

## A line the engine printed, to the bridge only: printed once already, it is not echoed.
func forward(message: String, error: bool) -> void:
	if otel_manager == null:
		return
	if error:
		otel_manager.GDS_LogError("", message, {})
	else:
		otel_manager.GDS_LogInformation("", message, {})

func logs_trace(section: String, message: String, tags: Dictionary = {}) -> void:
	if otel_manager == null:
		return
	if 0 >= otel_manager.GDS_GetLogLevelType() :
		otel_manager.GDS_LogTrace(section,message,tags)
		print_colored("trace",section,message)

func logs_debug(section: String, message: String, tags: Dictionary = {}) -> void:
	if otel_manager == null:
		return
	if 1 >= otel_manager.GDS_GetLogLevelType() :
		otel_manager.GDS_LogDebug(section,message,tags)
		print_colored("debug",section,message)

func logs_info(section: String, message: String, tags: Dictionary = {}) -> void:
	if otel_manager == null:
		return
	if 2 >= otel_manager.GDS_GetLogLevelType() :
		otel_manager.GDS_LogInformation(section,message,tags)
		print_colored("information",section,message)

func logs_warn(section: String, message: String, tags: Dictionary = {}) -> void:
	if otel_manager == null:
		return
	if 3 >= otel_manager.GDS_GetLogLevelType() :
		otel_manager.GDS_LogWarning(section,message,tags)
		print_colored("warning",section,message)

func logs_error(section: String, message: String, tags: Dictionary = {}) -> void:
	if otel_manager == null:
		return
	if 4 >= otel_manager.GDS_GetLogLevelType() :
		otel_manager.GDS_LogError(section,message,tags)
		print_colored("error",section,message)

func logs_crit(section: String, message: String, tags: Dictionary = {}) -> void:
	if otel_manager == null:
		return
	if 5 >= otel_manager.GDS_GetLogLevelType() :
		otel_manager.GDS_LogCritical(section,message,tags)
		print_colored("critical",section,message)

# Metric
func create_metric(metric_name: String, type: String) -> void:
	if otel_manager == null:
		return
	otel_manager.GDS_CreateMetric(metric_name,type)

func add_to_metric(metric_name: String, value: int,tags: Dictionary = {}) -> void:
	if otel_manager == null:
		return
	otel_manager.GDS_AddToMetric(metric_name,value,tags)

func add_to_record(metric_name: String, value: float,tags: Dictionary = {}) -> void:
	if otel_manager == null:
		return
	otel_manager.GDS_RecordHistogram(metric_name,value,tags)

# Traces

func start_trace(trace_name: String,tags: Dictionary = {}) -> String:
	if otel_manager == null:
		return ""
	return otel_manager.GDS_StartActivity(trace_name,tags)

func stop_trace(trace_id: String) -> void:
	if otel_manager == null:
		return
	otel_manager.GDS_StopActivity(trace_id)

func add_tags_to_trace(trace_id: String,tags: Dictionary = {}) -> void:
	if otel_manager == null:
		return
	otel_manager.GDS_AddTagsToActivity(trace_id,tags)
