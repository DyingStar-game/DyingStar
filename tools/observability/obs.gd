extends  Node

var sections :Dictionary= {
	"persistance" = "blue",
	"audio" = "green"
}

var levels :Dictionary= {
	"trace" = "grey",
	"debug" = "blue",
	"information" = "green",
	"warning" = "yellow",
	"error" = "red",
	"critical" = "purple"
}


var otel_manager = load("res://tools/observability/OpenTelemetryManager.cs").new()

func _ready() -> void:
	otel_manager._ready()
	logs_debug("audio","test")
	pass

# LOG

func print_colored(level: String, section: String, message: String) -> void:
	var sectionColor = sections.get(section,"white")
	var levelColor = levels.get(level,"white")
	var ownerColor = "white"
	if OS.has_feature("dedicated_server"):
		ownerColor = "white"
	else :
		ownerColor = "brown"
	
	print_rich("[color="+sectionColor+"][b]["+section+"][/b][/color] [color="+levelColor+"]"+level+"[/color] [color="+ownerColor+"] "+message+" [/color]")

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

func logs_Warn(section: String, message: String, tags: Dictionary = {}) -> void:
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
func create_metric(metricName: String, type: String) -> void:
	otel_manager.GDS_CreateMetric(metricName,type)

func add_to_metric(metricName: String, value: int,tags: Dictionary = {}) -> void:
	otel_manager.GDS_AddToMetric(metricName,value,tags)
	
func add_to_record(metricName: String, value: float,tags: Dictionary = {}) -> void:
	otel_manager.GDS_RecordHistogram(metricName,value,tags)

# Traces

func start_trace(traceName: String,tags: Dictionary = {}) -> String:
	return otel_manager.GDS_StartActivity(traceName,tags)

func stop_trace(traceid: String) -> void:
	otel_manager.GDS_StopActivity(traceid)

func add_tags_to_trace(traceid: String,tags: Dictionary = {}) -> void:
	otel_manager.GDS_AddTagsToActivity(traceid,tags)
