class_name TorchShadowBudget
extends Node
## Shadow budget for the OTHER players' head torches. Client-only, one instance, a child of the
## local player (built by PlayerClient.setup on the owner).
##
## Every avatar carries the same SpotLight3D torch with shadows, and its on/off state is replicated,
## so a crowd at night meant one shadow-casting spot per lit torch — and a shadowed light is a whole
## extra depth pass of everything in its cone (terrain, props, the other avatars), every frame.
## Measured on an empty scene: 30 lit torches = +5.4 ms/frame (test/perf/remote_players_bench
## `torch`); in the world each cone also holds terrain and props, so far more.
##
## Once a second, the lit remote torches within `max_distance` of the camera are sorted by distance
## and only the `max_shadows` nearest keep their shadow; every other torch still LIGHTS (the part
## one actually notices), it just casts nothing. Distance-ranked rather than thresholded, so a
## torch at the boundary does not flicker. The cost is bounded whatever the crowd; in a small group
## or by day nothing changes. The owner's own torch is not managed here and keeps its shadow.
const INTERVAL: float = 1.0

## How many remote torches may cast a shadow at once.
@export var max_shadows: int = 4
## Beyond this distance from the camera (m) a torch never casts (its beam is 25 m anyway).
@export var max_distance: float = 40.0

var _elapsed: float = INTERVAL  # evaluate on the first frame, then every INTERVAL

func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < INTERVAL:
		return
	_elapsed = 0.0
	_evaluate()

func _evaluate() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var eye: Vector3 = cam.global_position
	var candidates: Array = []  # [distance, torch] for every lit remote torch within range
	for p in get_tree().get_nodes_in_group("player"):
		if not p.remote_player:
			continue
		var torch: SpotLight3D = p.flashlight
		if torch == null or not is_instance_valid(torch):
			continue
		if not torch.visible:
			continue  # off: whatever its flag, it costs nothing; re-ranked when it lights up
		var d: float = eye.distance_to(torch.global_position)
		if d <= max_distance:
			candidates.append([d, torch])
		else:
			torch.shadow_enabled = false
	candidates.sort_custom(func(a, b): return a[0] < b[0])
	for i in candidates.size():
		candidates[i][1].shadow_enabled = i < max_shadows
