class_name ClientReadout
extends RefCounted
## The debug panel's Client section: this client's frame rate, what it holds, where it is, and the
## chunks the planet under it draws. An object rather than static functions because the event rates
## are measured between two of its own refreshes (see EventRate).

var _received := EventRate.new()
var _sent := EventRate.new()


func lines(body: Node3D) -> PackedStringArray:
	var agent : Node = NetworkOrchestrator.network_agent
	var out : PackedStringArray = [
		ReadoutFormat.graded(Engine.get_frames_per_second(), PerfReadout.FPS_GOOD, PerfReadout.FPS_FAIR, "FPS"),
		"%s players" % (str(agent.players_list.size()) if agent != null and "players_list" in agent else "-"),
		"%d objects" % int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"%s scenes" % _scenes(agent),
	]
	if is_instance_valid(body):
		var p : Vector3 = body.global_position
		out.append("x: %.2f" % p.x)
		out.append("y: %.2f" % p.y)
		out.append("z: %.2f" % p.z)
	out.append("%d MB video memory" % int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0))
	var now : int = Time.get_ticks_msec()
	out.append("%.0f events received/s · %.0f sent/s" % [
		_received.per_second(_total("network/events_received"), now),
		_sent.per_second(_total("network/events_sent"), now)])
	out.append(chunks_line(body))
	return out


## The chunks the planet we belong to has on screen — decided by its quadtree cut and Graphics >
## Terrain distance, which this number lets you watch.
static func chunks_line(body: Node3D) -> String:
	var planet : Planet = Planet.of(body) if is_instance_valid(body) else null
	if planet == null or planet.planet_terrain == null:
		return "- chunks"
	return "%d chunks (%s)" % [planet.planet_terrain.active_chunk_count(), planet.name]


static func _scenes(agent: Node) -> String:
	if agent == null or not "props_list" in agent:
		return "-"
	var count : int = 0
	for kind in agent.props_list:
		count += agent.props_list[kind].size()
	return str(count)


## The monitor's running total; 0 before the network agent registered it (and after it left).
static func _total(monitor: StringName) -> int:
	return int(Performance.get_custom_monitor(monitor)) if Performance.has_custom_monitor(monitor) else 0
