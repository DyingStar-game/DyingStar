class_name VrHandsCodec
extends RefCounted
## A VR player's two hands on the network ("vr_hands", Horizon's player zone 2: near players only):
## 30 bytes in base64, 40 characters, never the 26 joints of each hand. Per hand, in the BODY's frame
## (independent of the planet, the vehicle, the world's 4e10 m):
##
##   1 byte   flags (bit 0: the hand is there)
##   6 bytes  the wrist: 3 x int16, mm
##   4 bytes  the hand's turn: a quaternion, 4 x int8 (about a degree): its fingers and its back
##   4 bytes  how closed the index, middle, ring and little fingers are: 0..255 of VrArms.FINGER_MAX_DEG
##
## The other side puts it back on its avatar with the owner's own code (VrArms). "" says: no hands.
## A hand is a Dictionary as VrArms takes it: {"wrist", "forward", "dorsal", "curls"} (body's frame).
## Names no gameplay class but VrArms' constants: also read by the dedicated server (validation).

## Bytes of one hand, and of the pair.
const HAND_BYTES := 15
const BYTES := HAND_BYTES * 2
## Characters of the pair in base64 (30 bytes: no padding).
const TEXT_LENGTH := 40
## The wrist's grain (m per unit of its int16).
const MM := 0.001
## A hand is sent again once it moved this much (m, deg, share of a finger's travel).
const MOVE_M := 0.005
const TURN_DEG := 2.0
const CURL_SHARE := 0.05


## The pair of hands [param hands] ([left, right], each a hand or {} when not there) as text; "" when
## neither is there.
static func encode(hands: Array) -> String:
	if hands.size() != 2 or (hands[0].is_empty() and hands[1].is_empty()):
		return ""
	var bytes := PackedByteArray()
	bytes.resize(BYTES)
	for side in 2:
		_write(bytes, side * HAND_BYTES, hands[side])
	return Marshalls.raw_to_base64(bytes)


## [param text] back as [left, right] (each a hand or {}); [{}, {}] for "", [] when it is not a pair of
## hands at all.
static func decode(text: String) -> Array:
	if text == "":
		return [{}, {}]
	if text.length() != TEXT_LENGTH:
		return []
	var bytes: PackedByteArray = Marshalls.base64_to_raw(text)
	if bytes.size() != BYTES:
		return []
	return [_read(bytes, 0), _read(bytes, HAND_BYTES)]


## Is [param value] a "vr_hands" the server may relay (a String, "" or a pair of hands)?
static func valid(value: Variant) -> bool:
	return value is String and decode(value).size() == 2


## Has a hand gone from [param before] to [param now] far enough to be worth sending again?
static func changed_enough(before: Dictionary, now: Dictionary) -> bool:
	if before.is_empty() != now.is_empty():
		return true
	if now.is_empty():
		return false
	if (before["wrist"] as Vector3).distance_to(now["wrist"]) > MOVE_M:
		return true
	if rad_to_deg(_turn(before).angle_to(_turn(now))) > TURN_DEG:
		return true
	var a: PackedFloat32Array = closed(before["curls"])
	var b: PackedFloat32Array = closed(now["curls"])
	for f in a.size():
		if absf(a[f] - b[f]) > CURL_SHARE:
			return true
	return false


## How closed each finger is (0..1 of its joints' limits), from its bends [param curls] (deg, VrArms').
static func closed(curls: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for f in 4:
		var bends: Array = curls[f] if f < curls.size() else []
		var share: float = 0.0
		for j in bends.size():
			share += clampf(float(bends[j]) / VrArms.FINGER_MAX_DEG[mini(j, 2)], 0.0, 1.0)
		out.append(share / maxf(bends.size(), 1))
	return out


static func _write(bytes: PackedByteArray, at: int, hand: Dictionary) -> void:
	if hand.is_empty():
		return  # flags 0, the rest zeros
	bytes[at] = 1
	var wrist: Vector3 = hand["wrist"]
	for axis in 3:
		bytes.encode_s16(at + 1 + axis * 2, clampi(roundi(wrist[axis] / MM), -32768, 32767))
	var turn: Quaternion = _turn(hand)
	if turn.w < 0.0:
		turn = -turn  # one of the two quaternions of a turn: w >= 0
	var parts: Array[float] = [turn.x, turn.y, turn.z, turn.w]
	for c in 4:
		bytes.encode_s8(at + 7 + c, clampi(roundi(parts[c] * 127.0), -127, 127))
	var shares: PackedFloat32Array = closed(hand["curls"])
	for f in 4:
		bytes[at + 11 + f] = clampi(roundi(shares[f] * 255.0), 0, 255)


static func _read(bytes: PackedByteArray, at: int) -> Dictionary:
	if bytes[at] & 1 == 0:
		return {}
	var wrist := Vector3(bytes.decode_s16(at + 1), bytes.decode_s16(at + 3), bytes.decode_s16(at + 5)) * MM
	var turn := Quaternion(bytes.decode_s8(at + 7) / 127.0, bytes.decode_s8(at + 8) / 127.0,
			bytes.decode_s8(at + 9) / 127.0, bytes.decode_s8(at + 10) / 127.0)
	turn = turn.normalized() if turn.length_squared() > 1e-6 else Quaternion.IDENTITY
	var basis := Basis(turn)
	var curls: Array = []
	for f in 4:
		var share: float = bytes[at + 11 + f] / 255.0
		var bends: Array = []
		for limit: float in VrArms.FINGER_MAX_DEG:
			bends.append(share * limit)
		curls.append(bends)
	return {"wrist": wrist, "forward": basis.x, "dorsal": basis.y, "curls": curls}


## A hand's turn: the basis whose X goes along its fingers and whose Y out of its back.
static func _turn(hand: Dictionary) -> Quaternion:
	var x: Vector3 = (hand["forward"] as Vector3).normalized()
	var up: Vector3 = hand["dorsal"]
	var y: Vector3 = (up - x * up.dot(x)).normalized()
	return Basis(x, y, x.cross(y)).get_rotation_quaternion()
