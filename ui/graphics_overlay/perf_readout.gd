class_name PerfReadout
extends RefCounted
## The frame rate and the GPU time of the game view, the line that tells what an option costs:
## green from 60 FPS (16.7 ms), yellow from 30 (33.3 ms), red below.

const FPS_GOOD : float = 60.0
const FPS_FAIR : float = 30.0


static func lines() -> PackedStringArray:
	var rid : RID = (Engine.get_main_loop() as SceneTree).root.get_viewport_rid()
	# Harmless to repeat: a timestamp query per frame, which ClientPerf may have switched on already.
	RenderingServer.viewport_set_measure_render_time(rid, true)
	var gpu_ms : float = RenderingServer.viewport_get_measured_render_time_gpu(rid)
	return [ReadoutFormat.graded(Engine.get_frames_per_second(), FPS_GOOD, FPS_FAIR, "FPS")
		+ "  ·  GPU " + ReadoutFormat.graded(gpu_ms, 1000.0 / FPS_GOOD, 1000.0 / FPS_FAIR, "ms", true, 1)]
