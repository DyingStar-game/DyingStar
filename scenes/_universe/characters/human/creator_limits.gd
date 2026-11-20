class_name CreatorLimits
extends RefCounted

## How far a face may be pushed before it stops looking human, fitted on faces rated by eye
## (tools/character/face_survey/fit_limits.py writes creator_limits.json; 1 200 European faces, 2026-11-20).
##
## One slider alone, even at the end of its travel, hardly ever broke a face; several of one feature moved together
## did -- the mouth's first, then the eyes'. So a face carries a LOAD: over the catalogue's face tabs, the tab's
## weight times the sum of its sliders' squares; and the load stays within a BUDGET. FLAME's sliders (the creator's
## overall shape axes) are real faces' directions: they carry none, nor do the body's.
##
## Reversible: a stored look is never rewritten. limit() applies where a look is SHOWN (HumanAppearance) and the
## creator's sliders stop at the budget (max_move); turn strength down, or refit with another target, and every saved
## face shows again as it was made.

const LIMITS_PATH: String = "res://assets/_universe/characters/human/creator_limits.json"
## Slider values are stored in 127ths (CharacterAppearance.to_bytes): a limited value is rounded towards 0 on that grid,
## so that the stored look is the one shown, and still within the budget.
const STEPS: float = 127.0
## Slack on the budget for a load computed from rounded values.
const EPSILON: float = 1e-4

## 1 = the budget fitted on the verdicts; lower = looser (the budget is divided by it); 0 = no limit at all.
static var strength: float = 1.0
static var _budget: float = -1.0
static var _weights := PackedFloat32Array()


static func _ensure() -> void:
	if _budget >= 0.0:
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(LIMITS_PATH))
	var tabs: Dictionary = parsed.get("tabs", {}) if parsed is Dictionary else {}
	_budget = float(parsed.get("budget", INF)) if parsed is Dictionary else INF
	var sliders: Array = CharacterAppearance.catalogue()["modifiers"]
	_weights.resize(sliders.size())
	for id in sliders.size():
		_weights[id] = float(tabs.get(String(sliders[id]["tab"]), 0.0))


## The load a face may carry at the current strength (INF: no limit).
static func budget() -> float:
	_ensure()
	return INF if strength <= 0.0 else _budget / strength


## The load slider [param id] carries per squared unit (0: none).
static func weight(id: int) -> float:
	_ensure()
	return _weights[id] if id >= 0 and id < _weights.size() else 0.0


## The load of [param look]'s face.
static func load_of(look: CharacterAppearance) -> float:
	var total: float = 0.0
	for id: int in look.modifiers:
		var v: float = float(look.modifiers[id])
		total += weight(id) * v * v
	return total


## [param look] as it may be shown: a copy, within the budget. Over it, every slider that carries a load shrinks by
## the same factor -- the face keeps its character, only less of it. Idempotent.
static func limit(look: CharacterAppearance) -> CharacterAppearance:
	var out: CharacterAppearance = look.duplicate_appearance()
	var total: float = load_of(out)
	var allowed: float = budget()
	if total <= allowed + EPSILON:
		return out
	var shrink: float = sqrt(allowed / total)
	for id: int in out.modifiers.keys():
		if weight(id) > 0.0:
			var v: float = float(out.modifiers[id]) * shrink
			v = signf(v) * floorf(absf(v) * STEPS) / STEPS
			if v == 0.0:
				out.modifiers.erase(id)
			else:
				out.modifiers[id] = v
	return out


## How far slider [param id] of [param look] may go towards [param wanted], the others kept: [param wanted] if the
## budget allows it, else the furthest value on the way, on the stored grid. Back towards 0 is always allowed (a look
## made before the limits, or under a looser strength, may already be past them).
static func max_move(look: CharacterAppearance, id: int, wanted: float) -> float:
	var w: float = weight(id)
	if w <= 0.0:
		return wanted
	var current: float = float(look.modifiers.get(id, 0.0))
	var room: float = budget() - (load_of(look) - w * current * current)
	var reach: float = floorf(sqrt(maxf(room, 0.0) / w) * STEPS) / STEPS
	if absf(wanted) <= reach:
		return wanted
	if signf(wanted) == signf(current) and absf(current) > reach:
		return wanted if absf(wanted) <= absf(current) else current
	return signf(wanted) * reach
