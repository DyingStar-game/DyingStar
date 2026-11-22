extends GutTest
## A VR player's hands reach the players nearby ("vr_hands"): 30 bytes for both hands, never the joints
## (VrHandsCodec), sent when they moved enough to show (VrHandsSender), checked by the server, and played
## on the remote avatar by the owner's own arms (VrArms with the network as its source).


func _hand(wrist: Vector3, yaw: float, closed: float) -> Dictionary:
	var turn := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, 0.4)
	var curls: Array = []
	for f in 4:
		var bends: Array = []
		for limit: float in VrArms.FINGER_MAX_DEG:
			bends.append(limit * closed)
		curls.append(bends)
	return {"wrist": wrist, "forward": turn.x, "dorsal": turn.y, "curls": curls}


func test_both_hands_are_forty_characters_and_come_back_within_a_millimetre_and_a_degree() -> void:
	var sent: Array = [_hand(Vector3(-0.25, 1.1, -0.4), 0.3, 0.2), _hand(Vector3(0.31, 0.95, -0.35), -1.2, 0.9)]
	var text: String = VrHandsCodec.encode(sent)
	assert_eq(text.length(), VrHandsCodec.TEXT_LENGTH, "30 bytes, not 2 x 26 joints")
	var got: Array = VrHandsCodec.decode(text)
	for side in 2:
		assert_almost_eq(got[side]["wrist"], sent[side]["wrist"], Vector3.ONE * 0.0006)
		assert_lt(rad_to_deg((got[side]["forward"] as Vector3).angle_to(sent[side]["forward"])), 2.0)
		assert_lt(rad_to_deg((got[side]["dorsal"] as Vector3).angle_to(sent[side]["dorsal"])), 2.0)
		var a: PackedFloat32Array = VrHandsCodec.closed(got[side]["curls"])
		var b: PackedFloat32Array = VrHandsCodec.closed(sent[side]["curls"])
		for f in 4:
			assert_almost_eq(a[f], b[f], 0.01)


func test_one_hand_alone_and_none() -> void:
	var got: Array = VrHandsCodec.decode(VrHandsCodec.encode([{}, _hand(Vector3.ONE * 0.2, 0.0, 0.5)]))
	assert_true(got[0].is_empty(), "the left hand not seen: not there")
	assert_false(got[1].is_empty())
	assert_eq(VrHandsCodec.encode([{}, {}]), "", "no hands: an empty text")
	assert_eq(VrHandsCodec.decode(""), [{}, {}])


func test_the_server_relays_hands_or_nothing() -> void:
	assert_true(VrHandsCodec.valid(""))
	assert_true(VrHandsCodec.valid(VrHandsCodec.encode([_hand(Vector3.ZERO, 0.0, 0.0), {}])))
	assert_false(VrHandsCodec.valid("hello"), "not a pair of hands")
	assert_false(VrHandsCodec.valid("A".repeat(400)), "nor a long text riding the hands' channel")
	assert_false(VrHandsCodec.valid(12), "nor anything but text")


func test_hands_are_sent_again_only_when_they_moved_enough_to_show() -> void:
	var still := _hand(Vector3(0.2, 1.0, -0.3), 0.5, 0.4)
	var text: String = VrHandsCodec.encode([still, {}])
	var sent: Array = VrHandsCodec.decode(text)
	var trembled := _hand(Vector3(0.202, 1.0, -0.3), 0.51, 0.42)
	assert_eq(VrHandsSender.next_text(sent, text, [trembled, {}]), text, "2 mm, half a degree: not sent")
	var moved := _hand(Vector3(0.22, 1.0, -0.3), 0.5, 0.4)
	assert_ne(VrHandsSender.next_text(sent, text, [moved, {}]), text, "2 cm: sent")
	assert_eq(VrHandsSender.next_text(sent, text, [{}, {}]), "", "gone: says so")


func test_a_remote_avatar_s_arms_take_the_hands_from_the_network() -> void:
	var body := Node3D.new()
	add_child_autofree(body)
	var skeleton := Skeleton3D.new()
	skeleton.position = Vector3(0.0, 0.0, 0.1)
	skeleton.rotation.y = PI  # the puppet faces the body's forward
	body.add_child(skeleton)
	for bone: String in ["LeftUpperArm", "LeftLowerArm", "LeftHand", "RightUpperArm", "RightLowerArm", "RightHand"]:
		skeleton.add_bone(bone)
	var arms := VrArms.new()
	arms.setup(null, body)
	var hands: Array = VrHandsCodec.decode(VrHandsCodec.encode([{}, _hand(Vector3(0.3, 1.2, -0.4), 0.2, 0.5)]))
	arms.source = func(side: int) -> Dictionary: return hands[side]
	arms.carrying = func() -> bool: return false
	body.add_child(arms)
	arms._skeleton = skeleton
	arms._arms = VrArms.attach(skeleton)
	arms._process(1.0)
	var right: Dictionary = arms._arms[1]
	var expected: Vector3 = LocalFrame.of(skeleton, body).affine_inverse() * (hands[1]["wrist"] as Vector3)
	assert_almost_eq(right["ik"].target, expected, Vector3.ONE * 1e-5, "the wrist where the network says")
	assert_true(right["ik"].active, "the right arm follows")
	assert_false(arms._arms[0]["ik"].active, "no left hand sent: the clip's arm")
