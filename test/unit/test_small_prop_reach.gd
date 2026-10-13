extends GutTest
## A small prop lying on the floor is in reach of a standing player. The interact ray starts at the
## eye (1.62 m) and is 1.5 m long, so a ration or a tool on its side (10 cm high) was out of reach
## standing — and a crouched player may not lift anything: no prompt, no way to take it. Their aim
## volume (the layer-32 Area3D the ray looks for) is a sphere, the same whichever side they land on.

const PLAYER := "res://scenes/player/player.tscn"
const PROPS: Array[String] = [
	"res://scenes/_universe/props/food/food_biscuit.tscn",
	"res://scenes/_universe/props/food/food_nutrigris.tscn",
	"res://scenes/_universe/props/tools/mining_tool_prop.tscn",
]
## How far in front of the feet (m) a prop on the floor must still be reachable.
const FLOOR_REACH_M := 0.5


## Height (m) of the eye — the CameraPivot the interact ray hangs from — above the player's origin.
func _eye_height() -> float:
	var state: SceneState = (load(PLAYER) as PackedScene).get_state()
	for i in state.get_node_count():
		if state.get_node_name(i) != &"CameraPivot":
			continue
		for p in state.get_node_property_count(i):
			if state.get_node_property_name(i, p) == &"transform":
				return (state.get_node_property_value(i, p) as Transform3D).origin.y
	return 0.0


func test_a_prop_on_the_floor_is_in_reach_standing() -> void:
	var eye: float = _eye_height()
	var reach: float = float((load("res://scenes/player/player.gd") as GDScript)
			.get_property_default_value("interact_ray_length"))
	assert_gt(eye, 1.0, "the eye of a standing player")
	for path: String in PROPS:
		var prop: Node = (load(path) as PackedScene).instantiate()
		var aim := prop.get_node("Area3D/CollisionShape3D") as CollisionShape3D
		assert_true(aim.shape is SphereShape3D, "%s: a sphere, whichever side it lies on" % path.get_file())
		if aim.shape is SphereShape3D:
			# Lying on the floor its centre is at least at floor level: the top of the sphere is this high.
			var drop: float = eye - (aim.shape as SphereShape3D).radius
			var ahead: float = sqrt(maxf(reach * reach - drop * drop, 0.0))
			assert_gt(ahead, FLOOR_REACH_M, "%s: reached on the floor up to %.2f m ahead" % [path.get_file(), ahead])
		prop.free()
