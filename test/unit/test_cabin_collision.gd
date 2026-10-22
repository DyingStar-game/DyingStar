extends GutTest
## The shower and restroom cabins collide as five boxes (back, two sides, floor, ceiling; the door has its
## own), not as a triangle mesh: a ConcavePolygonShape3D of ~640 triangles in each of the 252 homes' cabins
## was dear to the servers' physics. The boxes hold the old shell's bounds, and a player fits inside.

const CABINS := [
	"res://scenes/_universe/props/furniture/hygene/shower_cabin.tscn",
	"res://scenes/_universe/props/furniture/hygene/restroom_cabin.tscn",
]
## The old shell's bounds in the cabin's space (m): what the boxes must still close.
const SHELL := AABB(Vector3(-0.75, 0.0, -0.854), Vector3(1.5, 2.5, 1.711))
## A standing player in the middle of the cabin: 0.6 m wide, 1.8 m tall, on its floor.
const PLAYER := AABB(Vector3(-0.3, 0.05, -0.3), Vector3(0.6, 1.8, 0.6))


func test_a_cabin_collides_as_boxes() -> void:
	for path: String in CABINS:
		var cabin: Node = (load(path) as PackedScene).instantiate()
		var boxes := 0
		for child: Node in cabin.get_children():
			if child is CollisionShape3D:
				assert_false((child as CollisionShape3D).shape is ConcavePolygonShape3D, "%s: %s" % [path, child.name])
				if (child as CollisionShape3D).shape is BoxShape3D:
					boxes += 1
		assert_eq(boxes, 5, path)
		cabin.free()


func test_the_boxes_close_the_old_shell_and_leave_room_for_a_player() -> void:
	for path: String in CABINS:
		var cabin: Node = (load(path) as PackedScene).instantiate()
		var union := AABB()
		var first := true
		for child: Node in cabin.get_children():
			var cs := child as CollisionShape3D
			if cs == null or not cs.shape is BoxShape3D:
				continue
			var size: Vector3 = (cs.shape as BoxShape3D).size
			var box: AABB = cs.transform * AABB(-size * 0.5, size)
			union = box if first else union.merge(box)
			first = false
			assert_false(box.intersects(PLAYER), "%s: %s leaves room for a player" % [path, cs.name])
		for axis in 3:
			assert_almost_eq(union.position[axis], SHELL.position[axis], 0.01, "%s: corner, axis %d" % [path, axis])
			assert_almost_eq(union.end[axis], SHELL.end[axis], 0.01, "%s: far corner, axis %d" % [path, axis])
		cabin.free()
