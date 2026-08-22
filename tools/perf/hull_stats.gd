@tool
extends SceneTree
## Prices the two halves of Mesh.create_convex_shape() on the mining-rock mesh: `simplify=true`
## (which routes through the convex DECOMPOSITION path) versus plain QuickHull. The client
## heartbeat says the simplify path costs ~95 ms per rock; this says what the cheap one costs and
## how much heavier a collider it leaves behind.
func _init() -> void:
	var m: Mesh = load("res://assets/_universe/environment/terrain/rocks/rock_mining_001.mesh")
	for simplify in [false, true]:
		var t0 := Time.get_ticks_usec()
		var s: ConvexPolygonShape3D = m.create_convex_shape(true, simplify)
		var dt := Time.get_ticks_usec() - t0
		print("simplify=%s  ->  %.2f ms, %d hull points" % [simplify, dt / 1000.0, s.points.size() if s != null else -1])
	quit()
