class_name CreatorLimits
extends RefCounted

## How far a face may be pushed before it stops looking human, fitted on faces rated by eye
## (tools/character/face_survey/fit_limits.py writes creator_limits.json; 1 200 European faces, 2026-11-20).
##
## One slider alone, even at the end of its travel, hardly ever broke a face; several of one feature moved together
## did -- the mouth's first, then the eyes'. So a face carries a LOAD: over the catalogue's face tabs, the tab's
## weight times the sum of its sliders' squares; and the load stays within a BUDGET. A slider that breaks faces sooner
## one way has a weight of its own that way (the lower lip's corners pulled down). FLAME's sliders (the creator's
## overall shape axes) are real faces' directions: they carry none, nor do the body's.
## The body takes its sliders well, together too: only a CAP stops the odd one that breaks it alone, that way, at a
## value (BodyType_Emaciated, 2026-11-21), outside the load.
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
## Per catalogue slider id, the load per squared unit below 0 and above it.
static var _down := PackedFloat32Array()
static var _up := PackedFloat32Array()
## Per catalogue slider id, the furthest it may go below 0 (as a positive value) and above it (INF: no cap).
static var _cap_down := PackedFloat32Array()
static var _cap_up := PackedFloat32Array()


static func _ensure() -> void:
	if _budget >= 0.0:
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(LIMITS_PATH))
	var tabs: Dictionary = parsed.get("tabs", {}) if parsed is Dictionary else {}
	_budget = float(parsed.get("budget", INF)) if parsed is Dictionary else INF
	var directions: Dictionary = parsed.get("directions", {}) if parsed is Dictionary else {}
	var caps: Dictionary = parsed.get("caps", {}) if parsed is Dictionary else {}
	var sliders: Array = CharacterAppearance.catalogue()["modifiers"]
	_down.resize(sliders.size())
	_up.resize(sliders.size())
	_cap_down.resize(sliders.size())
	_cap_up.resize(sliders.size())
	for id in sliders.size():
		var tab_weight: float = float(tabs.get(String(sliders[id]["tab"]), 0.0))
		var own: Dictionary = directions.get(String(sliders[id]["key"]), {})
		_down[id] = float(own.get("-", tab_weight))
		_up[id] = float(own.get("+", tab_weight))
		var cap_of: Dictionary = caps.get(String(sliders[id]["key"]), {})
		_cap_down[id] = float(cap_of.get("-", INF))
		_cap_up[id] = float(cap_of.get("+", INF))


## The load a face may carry at [param at_strength] (negative: the current strength; INF: no limit).
static func budget(at_strength: float = -1.0) -> float:
	_ensure()
	var s: float = strength if at_strength < 0.0 else at_strength
	return INF if s <= 0.0 else _budget / s


## How far slider [param id] may go towards [param v]'s side at [param at_strength] (as budget()), on the stored grid:
## its cap, tighter as the strength rises (a load goes as the square: the cap by its root); INF: none.
static func cap(id: int, v: float, at_strength: float = -1.0) -> float:
	_ensure()
	var s: float = strength if at_strength < 0.0 else at_strength
	if s <= 0.0 or id < 0 or id >= _cap_up.size():
		return INF
	var raw: float = _cap_down[id] if v < 0.0 else _cap_up[id]
	return INF if is_inf(raw) else floorf(raw / sqrt(s) * STEPS) / STEPS


## The load slider [param id] carries per squared unit, set to [param v] (0: none).
static func weight(id: int, v: float) -> float:
	_ensure()
	if id < 0 or id >= _up.size():
		return 0.0
	return _down[id] if v < 0.0 else _up[id]


## The load of [param look]'s face.
static func load_of(look: CharacterAppearance) -> float:
	var total: float = 0.0
	for id: int in look.modifiers:
		var v: float = float(look.modifiers[id])
		total += weight(id, v) * v * v
	return total


## [param look] as it may be shown: a copy, within the budget and the caps. Over the budget, every slider that carries
## a load shrinks by the same factor -- the face keeps its character, only less of it; a slider past its cap stops at
## it. Idempotent. [param at_strength]: as budget().
static func limit(look: CharacterAppearance, at_strength: float = -1.0) -> CharacterAppearance:
	var out: CharacterAppearance = look.duplicate_appearance()
	var total: float = load_of(out)
	var allowed: float = budget(at_strength)
	if total > allowed + EPSILON:
		var shrink: float = sqrt(allowed / total)
		for id: int in out.modifiers.keys():
			if weight(id, float(out.modifiers[id])) > 0.0:
				var v: float = float(out.modifiers[id]) * shrink
				v = signf(v) * floorf(absf(v) * STEPS) / STEPS
				if v == 0.0:
					out.modifiers.erase(id)
				else:
					out.modifiers[id] = v
	for id: int in out.modifiers.keys():
		var v: float = float(out.modifiers[id])
		var most: float = cap(id, v, at_strength)
		if absf(v) > most:
			out.modifiers[id] = signf(v) * most
	return out


## How far slider [param id] of [param look] may go towards [param wanted], the others kept: [param wanted] if the
## budget allows it, else the furthest value on the way, on the stored grid. Back towards 0 is always allowed (a look
## made before the limits, or under a looser strength, may already be past them).
static func max_move(look: CharacterAppearance, id: int, wanted: float) -> float:
	var w: float = weight(id, wanted)
	var reach: float = cap(id, wanted)
	if w <= 0.0 and is_inf(reach):
		return wanted
	var current: float = float(look.modifiers.get(id, 0.0))
	if w > 0.0:
		var room: float = budget() - (load_of(look) - weight(id, current) * current * current)
		reach = minf(reach, floorf(sqrt(maxf(room, 0.0) / w) * STEPS) / STEPS)
	if absf(wanted) <= reach:
		return wanted
	if signf(wanted) == signf(current) and absf(current) > reach:
		return wanted if absf(wanted) <= absf(current) else current
	return signf(wanted) * reach
