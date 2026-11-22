extends GutTest
## The torch is worn on the head. Lying on a bed the head lies with the body while the view turns in
## the frame of the upright body the bed holds: the beam must then go where the player LOOKS, feet
## included, and go back to riding the head once up (CharacterAnimator.aim_torch).

const OFFSET := Vector3(0.0, 0.08, -0.2)

var _mount: Node3D
var _torch: SpotLight3D
var _view: Node3D


func before_each() -> void:
	_mount = Node3D.new()
	add_child_autofree(_mount)
	# The head as the lay clip leaves it: on the pillow, its "forward" to the ceiling.
	_mount.global_transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(90.0)), Vector3(1.0, 0.6, 2.0))
	_torch = SpotLight3D.new()
	_mount.add_child(_torch)
	_torch.transform = Transform3D(Basis(), OFFSET)
	_view = Node3D.new()
	add_child_autofree(_view)


func _forward(node: Node3D) -> Vector3:
	return -node.global_basis.z.normalized()


func test_lying_the_beam_goes_where_the_view_looks() -> void:
	assert_almost_eq(_forward(_torch).dot(Vector3.UP), 1.0, 0.001, "riding the head: to the ceiling")
	_view.rotation = Vector3(deg_to_rad(-20.0), 0.0, 0.0)  # towards one's feet, a little down
	CharacterAnimator.aim_torch(_torch, _view, true)
	assert_almost_eq(_forward(_torch).dot(_forward(_view)), 1.0, 0.001, "the beam is the view's")
	assert_lt(_forward(_torch).y, 0.0, "and so it comes down to the feet")


func test_lying_the_torch_stays_on_the_head() -> void:
	var before: Vector3 = _torch.global_position
	_view.rotation = Vector3(deg_to_rad(-20.0), deg_to_rad(35.0), 0.0)
	CharacterAnimator.aim_torch(_torch, _view, true)
	assert_almost_eq(_torch.global_position.distance_to(before), 0.0, 0.001, "aimed, not moved")


func test_up_again_the_torch_rides_the_head() -> void:
	_view.rotation = Vector3(deg_to_rad(-20.0), deg_to_rad(35.0), 0.0)
	CharacterAnimator.aim_torch(_torch, _view, true)
	CharacterAnimator.aim_torch(_torch, _view, false)
	assert_true(_torch.basis.is_equal_approx(Basis.IDENTITY), "back to the mount's own direction")
	assert_almost_eq(_torch.position.distance_to(OFFSET), 0.0, 0.001, "its offset untouched")
