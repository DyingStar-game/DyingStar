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


var otel_manager = load("res://tools/observability/OpenTelemetryManager.cs").new()

func _ready() -> void:
	otel_manager._ready()
	OS.add_logger(CustomLogger.new())
	Obs.logs_info("engine","Ready for obs")
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

func logs_trace(section: String, message: String, tags: Dictionary = {}) -> void:
	if 0 >= otel_manager.GDS_GetLogLevelType() :
		otel_manager.GDS_LogTrace(section,message,tags)
		print_colored("trace",section,message)

func logs_debug(section: String, message: String, tags: Dictionary = {}) -> void:
	if 1 >= otel_manager.GDS_GetLogLevelType() :
		otel_manager.GDS_LogDebug(section,message,tags)
		print_colored("debug",section,message)

func logs_info(section: String, message: String, tags: Dictionary = {}) -> void:
	if 2 >= otel_manager.GDS_GetLogLevelType() :
		otel_manager.GDS_LogInformation(section,message,tags)
		print_colored("information",section,message)

func logs_warn(section: String, message: String, tags: Dictionary = {}) -> void:
	if 3 >= otel_manager.GDS_GetLogLevelType() :
		otel_manager.GDS_LogWarning(section,message,tags)
		print_colored("warning",section,message)

func logs_error(section: String, message: String, tags: Dictionary = {}) -> void:
	if 4 >= otel_manager.GDS_GetLogLevelType() :
		otel_manager.GDS_LogError(section,message,tags)
		print_colored("error",section,message)

func logs_crit(section: String, message: String, tags: Dictionary = {}) -> void:
	if 5 >= otel_manager.GDS_GetLogLevelType() :
		otel_manager.GDS_LogCritical(section,message,tags)
		print_colored("critical",section,message)

# Metric
func create_metric(metric_name: String, type: String) -> void:
	otel_manager.GDS_CreateMetric(metric_name,type)

func add_to_metric(metric_name: String, value: int,tags: Dictionary = {}) -> void:
	otel_manager.GDS_AddToMetric(metric_name,value,tags)

func add_to_record(metric_name: String, value: float,tags: Dictionary = {}) -> void:
	otel_manager.GDS_RecordHistogram(metric_name,value,tags)

# Traces

func start_trace(trace_name: String,tags: Dictionary = {}) -> String:
	return otel_manager.GDS_StartActivity(trace_name,tags)

func stop_trace(trace_id: String) -> void:
	otel_manager.GDS_StopActivity(trace_id)

func add_tags_to_trace(trace_id: String,tags: Dictionary = {}) -> void:
	otel_manager.GDS_AddTagsToActivity(trace_id,tags)
