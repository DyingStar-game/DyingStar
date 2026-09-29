class_name PerfReadout
extends RefCounted
## The frame rate and the GPU time of the game view, the line that tells what an option costs.


static func lines() -> PackedStringArray:
	var rid : RID = (Engine.get_main_loop() as SceneTree).root.get_viewport_rid()
	# Harmless to repeat: a timestamp query per frame, which ClientPerf may have switched on already.
	RenderingServer.viewport_set_measure_render_time(rid, true)
	return [ReadoutFormat.rated(Engine.get_frames_per_second(), 30.0, "FPS")
		+ "  ·  GPU %.1f ms" % RenderingServer.viewport_get_measured_render_time_gpu(rid)]
