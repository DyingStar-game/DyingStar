class_name FaceAxes
extends RefCounted

## The creator's "overall shape" sliders: each moves several sliders at once, along a direction a face is
## described by (wide or narrow, long or short, a square jaw, strong features, open eyes...).
##
## Each axis is a direction of FLAME's space of real faces (face_axes.json, tools/character/flame/make_axes.py): the
## one that changes its named measure the most for the least improbable face, so that what goes together in real
## faces goes together on the axis.
##
## An axis is only a way of editing: nothing of it is stored. What a look holds is the sliders; an axis' position
## is read back from them (value_of: the least-squares projection of the look's sliders on the axis), and moving it
## adds its direction to them (move).

const AXES_PATH: String = "res://assets/_universe/characters/human/face_axes.json"

static var _axes: Array = []


## The axes: [id, label (translation key), {slider id: share}], shares being stored slider values at full travel.
static func axes() -> Array:
	if _axes.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(AXES_PATH))
		for axis: Dictionary in (parsed["axes"] if parsed is Dictionary else []):
			var shares: Dictionary = {}
			for key: String in axis["shares"]:
				var id: int = CharacterAppearance.modifier_id(key)
				if id != -1:
					shares[id] = float(axis["shares"][key])
			_axes.append([StringName(axis["id"]), String(axis["label"]), shares])
	return _axes


## Where [param look] lies along an axis' direction ({id: share}), -1..1: the least-squares projection
## of its sliders.
static func value_of(look: CharacterAppearance, shares: Dictionary) -> float:
	var along: float = 0.0
	var norm: float = 0.0
	for id: int in shares:
		along += float(look.modifiers.get(id, 0.0)) * shares[id]
		norm += shares[id] * shares[id]
	return clampf(along / norm, -1.0, 1.0) if norm > 0.0 else 0.0


## Move [param look] by [param delta] along an axis' direction: each of its sliders by its share, kept in
## its range (a one-sided slider never goes below 0), zeros dropped.
static func move(look: CharacterAppearance, shares: Dictionary, delta: float) -> void:
	var sliders: Array = CharacterAppearance.catalogue()["modifiers"]
	for id: int in shares:
		var lowest: float = 0.0 if sliders[id]["unipolar"] else -1.0
		var v: float = clampf(float(look.modifiers.get(id, 0.0)) + delta * shares[id], lowest, 1.0)
		if absf(v) < 0.5 / 127.0:
			look.modifiers.erase(id)
		else:
			look.modifiers[id] = v
