class_name NativeScript
extends RefCounted
## Loading a C# twin so that a missing OR STALE assembly falls back to the GDScript instead of failing.
##
## load() alone is not enough. The .cs file is always there, and loads, whatever DyingStar.dll holds;
## when the assembly was built before a class or a method existed — a pull followed by headless tests
## or a probe, where nothing rebuilds it — the instance comes out without the method, and the first
## call fails ("Nonexistent function 'Configure' in base 'RefCounted (MountainZoneNative.cs)'", seen
## 2026-09-23). The GDScript twin would have answered the same values; it just was never asked.
##
## So a twin is used only once an instance of it has been made and found to carry every method its
## caller will call. The probe instance is dropped at once: one per script, per session.


## [param path]'s script when it can really be used — it loads, instantiates, and the instance has
## every method of [param methods] — else null, and the caller keeps its GDScript path.
static func load_usable(path: String, methods: Array[String]) -> Script:
	if not ResourceLoader.exists(path):
		return null
	var script: Script = load(path) as Script
	if script == null or not script.can_instantiate():
		return null
	var probe: Object = script.new()
	if probe == null:
		return null
	for method: String in methods:
		if not probe.has_method(method):
			return null
	return script
