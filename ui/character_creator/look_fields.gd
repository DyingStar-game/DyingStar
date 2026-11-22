class_name LookFields
extends RefCounted

## Every field of a look the character creator edits, by a stable key, and the creator's random draws over them:
## a line's die, a menu's "Random", "All random" and "Vary", each leaving the LOCKED fields as they are.
##
## Keys: "macro:gender|age|height", "origin:<i>", "mod:<catalogue key>" (a slider), "axis:<id>" (an overall shape
## axis, FaceAxes: kept by its position, its sliders moved back along it), "prop:<property>" (skin, hair colour,
## eyebrows, eyelashes, eye colour), "hair_style" / "beard_style" (the asset and the whole cut it starts),
## "cut:<field>" / "beard_cut:<field>", "garment:<zone>:<layer>" (an outfit picker's garments).
##
## Coherent draws: a draw that does not touch the sex nor the origins takes its values from a random look of the
## same sex and main origin (random_like), so a skin, a head of hair or a face drawn goes with the character.

const FACE_TABS: Array = ["head", "eyes", "nose", "mouth", "jaw", "ears"]
const FLAME_TAB: String = "flame"
const SKIN_PROPS: Array = ["skin_tone", "skin_warmth", "freckles", "moles", "wrinkles", "redness", "eye_bags", "unevenness",
	"dimples"]
const HAIR_COLOUR_PROPS: Array = ["hair_eumelanin", "hair_pheomelanin", "hair_grey"]
const CUT_FIELDS: Array = ["length", "sides", "volume", "curl", "density", "fringe", "recession", "crown_bald", "low_line",
	"flyaways", "part", "tie"]
const BEARD_FIELDS: Array = ["length", "moustache", "chin", "cheeks", "neck", "connect", "density", "shape"]
## A catalogue face slider's spread when drawn alone (stored value), where face_stats.json does not measure it.
const FACE_SPREAD: float = 0.2
## "Vary": each field moved by a normal draw of this deviation (stored units); a face slider by VARY_FACE of its spread.
const VARY_FACE: float = 0.3
const VARY_FLAME: float = 0.05
const VARY_BODY: float = 0.08
const VARY_COLOUR: float = 0.04
const VARY_CUT: float = 0.05
## random_like: seeds tried for a look of the asked sex and origin (7 South Asian origins: ~1 in 84).
const LIKE_TRIES: int = 800
const LIKE_STRIDE: int = 1000003
const FACE_STATS_PATH: String = "res://assets/_universe/characters/human/face_stats.json"

static var _spread: Dictionary = {}


## The keys of a creator menu ([param tab], [param subtab]), in the order its lines show them.
static func menu_keys(tab: StringName, subtab: StringName) -> Array:
	var keys: Array = []
	match tab:
		&"body":
			if subtab == &"shape":
				keys.append_array(["macro:gender", "macro:age", "macro:height"])
				keys.append_array(_mod_keys("shape"))
				for i in CharacterAppearance.ORIGINS:
					keys.append("origin:%d" % i)
			else:
				keys.append_array(_mod_keys(String(subtab)))
		&"face":
			if subtab == &"overall":
				for axis: Array in FaceAxes.axes():
					keys.append("axis:%s" % axis[0])
				keys.append_array(_mod_keys(FLAME_TAB))  # what the axes move: drawn and locked with them
			else:
				keys.append_array(_mod_keys(String(subtab)))
		&"skin":
			for p: String in SKIN_PROPS:
				keys.append("prop:" + p)
		&"hair":
			keys.append("hair_style")
			for f: String in CUT_FIELDS:
				keys.append("cut:" + f)
			for p: String in HAIR_COLOUR_PROPS:
				keys.append("prop:" + p)
			keys.append("beard_style")
			for f: String in BEARD_FIELDS:
				keys.append("beard_cut:" + f)
			keys.append_array(["prop:eyebrows", "prop:eyelashes"])
		&"eyes":
			keys.append("prop:eye_colour")
		&"outfit":
			for zone: Array in CharacterCreator.GARMENT_ZONES:
				for layer in CharacterCreator.GARMENT_LAYERS.size():
					if not garment_choices(String(zone[0]), layer).is_empty():
						keys.append("garment:%s:%d" % [zone[0], layer])
	return keys


## Every key of every menu.
static func all_keys() -> Array:
	var keys: Array = []
	for tab: StringName in CharacterCreator.TABS:
		var subs: Dictionary = CharacterCreator.SUBTABS.get(tab, {&"": ""})
		for sub: StringName in subs:
			for k: String in menu_keys(tab, sub):
				if not keys.has(k):
					keys.append(k)
	return keys


## The garments (catalogue positions) an outfit picker offers: zone [param zone] (a GDD zone's first character),
## layer [param layer].
static func garment_choices(zone: String, layer: int) -> Array[int]:
	var choices: Array[int] = []
	var entries: Array = CharacterAppearance.garment_entries()
	for i in entries.size():
		var e: Dictionary = entries[i]
		var zones: Array = e.get("zones", [])
		if String(e["id"]) == "none" or zones.is_empty() or int(e.get("layer", 1)) != layer:
			continue
		if String(zones[0]).left(1) == zone:
			choices.append(i)
	return choices


## The value of [param key] in [param look] (to compare two looks; a garment key gives its worn positions).
static func value(look: CharacterAppearance, key: String) -> Variant:
	var kind: String = key.get_slice(":", 0)
	var name: String = key.substr(kind.length() + 1)
	match kind:
		"macro":
			return float(look.macros.get(name, 0.0))
		"origin":
			return look.origins[int(name)]
		"mod":
			return float(look.modifiers.get(CharacterAppearance.modifier_id(name), 0.0))
		"axis":
			return FaceAxes.value_of(look, _axis_shares(name))
		"prop":
			return look.get(name)
		"cut":
			return look.cut.get(name)
		"beard_cut":
			return look.beard_cut.get(name)
		"hair_style":
			return look.hair
		"beard_style":
			return look.beard
		"garment":
			var choices: Array[int] = garment_choices(name.get_slice(":", 0), int(name.get_slice(":", 1)))
			var worn: Array = []
			for g: Array in look.garments:
				if choices.has(int(g[0])):
					worn.append(int(g[0]))
			return worn
	return null


## [param key]'s value from [param from] into [param to]. An axis moves [param to] along its direction to
## [param from]'s position; a style brings its whole cut; a garment row its garments (dressed() is for the caller).
static func copy(from: CharacterAppearance, to: CharacterAppearance, key: String) -> void:
	var kind: String = key.get_slice(":", 0)
	var name: String = key.substr(kind.length() + 1)
	match kind:
		"macro":
			to.macros[name] = from.macros.get(name, to.macros.get(name, 0.0))
		"origin":
			to.origins[int(name)] = from.origins[int(name)]
		"mod":
			var id: int = CharacterAppearance.modifier_id(name)
			if from.modifiers.has(id):
				to.modifiers[id] = from.modifiers[id]
			else:
				to.modifiers.erase(id)
		"axis":
			var shares: Dictionary = _axis_shares(name)
			for i in 3:  # the axes overlap: what another axis moved is taken back again
				FaceAxes.move(to, shares, FaceAxes.value_of(from, shares) - FaceAxes.value_of(to, shares))
		"prop":
			to.set(name, from.get(name))
		"cut":
			to.cut.set(name, from.cut.get(name))
		"beard_cut":
			to.beard_cut.set(name, from.beard_cut.get(name))
		"hair_style":
			to.hair = from.hair
			to.cut = HairCut.from_bytes(from.cut.to_bytes())
			to.hair_length = from.hair_length
		"beard_style":
			to.beard = from.beard
			to.beard_cut = BeardCut.from_bytes(from.beard_cut.to_bytes())
			to.beard_length = from.beard_length
		"garment":
			var choices: Array[int] = garment_choices(name.get_slice(":", 0), int(name.get_slice(":", 1)))
			var kept: Array = to.garments.filter(func(g: Array) -> bool: return not choices.has(int(g[0])))
			for g: Array in from.garments:
				if choices.has(int(g[0])):
					kept.push_front([int(g[0]), int(g[1])])
			to.garments = kept


## [param current] with the fields of [param keys] drawn again, the [param locks] ({key: true}) kept: a line's die
## (one key), a menu's "Random" (its keys), "All random" (all_keys). Deterministic for a [param seed_value].
static func draw(current: CharacterAppearance, keys: Array, locks: Dictionary, seed_value: int) -> CharacterAppearance:
	var free: Array = keys.filter(func(k: String) -> bool: return not locks.get(k, false))
	var identity: bool = free.any(func(k: String) -> bool: return k == "macro:gender" or k.begins_with("origin:"))
	var drawn: CharacterAppearance
	if identity:
		drawn = CharacterAppearance.random(seed_value)
		# what of the sex and the origins is locked is the character's: drawn again with them
		if locks.get("macro:gender", false) or _origins_locked(locks):
			drawn = random_like(seed_value, int(current.is_female()) if locks.get("macro:gender", false) else -1,
					main_origin(current) if _origins_locked(locks) else -1)
	else:
		drawn = random_like(seed_value, int(current.is_female()), main_origin(current))
	var whole: bool = keys.size() >= all_keys().size()
	var out: CharacterAppearance = drawn.duplicate_appearance() if whole else current.duplicate_appearance()
	if not whole:
		for k: String in free:
			copy(drawn, out, k)
		var rng := RandomNumberGenerator.new()
		rng.seed = hash([seed_value, "face sliders"])
		for k: String in free:
			if k.begins_with("mod:") and _is_face_slider(k):
				_draw_face_slider(current, out, k, rng)
	_restore(current, out, locks, keys if not whole else all_keys())
	_finish(out)
	return out


## [param current] with each unlocked field of [param keys] moved a little ("Vary"): sliders and colours by a
## small normal draw, choices kept. Deterministic for a [param seed_value].
static func vary(current: CharacterAppearance, keys: Array, locks: Dictionary, seed_value: int) -> CharacterAppearance:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var out: CharacterAppearance = current.duplicate_appearance()
	for k: String in keys:
		if locks.get(k, false):
			continue
		var kind: String = k.get_slice(":", 0)
		var name: String = k.substr(kind.length() + 1)
		match kind:
			"mod":
				var id: int = CharacterAppearance.modifier_id(name)
				var entry: Dictionary = CharacterAppearance.catalogue()["modifiers"][id]
				var tab: String = String(entry["tab"])
				var spread: float = VARY_FLAME if tab == FLAME_TAB \
						else (VARY_FACE * face_spread(name) if FACE_TABS.has(tab) else VARY_BODY)
				_set_slider(out, id, float(out.modifiers.get(id, 0.0)) + rng.randfn(0.0, spread), float(out.modifiers.get(id, 0.0)))
			"macro":
				out.macros[name] = clampf(float(out.macros[name]) + rng.randfn(0.0, VARY_BODY * 0.5), 0.0, 1.0)
			"prop":
				if out.get(name) is float:
					out.set(name, clampf(float(out.get(name)) + rng.randfn(0.0, VARY_COLOUR), 0.0, 1.0))
			"cut", "beard_cut":
				var target: Object = out.cut if kind == "cut" else out.beard_cut
				if target.get(name) is float:
					target.set(name, clampf(float(target.get(name)) + rng.randfn(0.0, VARY_CUT), 0.0, 1.0))
	_restore(current, out, locks, keys)
	_finish(out)
	return out


## The first look random() draws from [param seed_value] on (every LIKE_STRIDE) that is a woman when
## [param female] is 1, a man when 0, and whose main origin is [param origin] (-1: any).
static func random_like(seed_value: int, female: int, origin: int) -> CharacterAppearance:
	var s: int = seed_value
	var a: CharacterAppearance
	for i in LIKE_TRIES:
		a = CharacterAppearance.random(s)
		if (female < 0 or int(a.is_female()) == female) and (origin < 0 or main_origin(a) == origin):
			return a
		s += LIKE_STRIDE
	return a


## The origin [param look] has most of.
static func main_origin(look: CharacterAppearance) -> int:
	var best: int = 0
	for i in CharacterAppearance.ORIGINS:
		if look.origins[i] > look.origins[best]:
			best = i
	return best


## A catalogue face slider's spread in real faces (face_stats.json, stored value), else FACE_SPREAD.
static func face_spread(key: String) -> float:
	if _spread.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(FACE_STATS_PATH))
		var sliders: Dictionary = parsed.get("sliders", {}) if parsed is Dictionary else {}
		_spread[""] = FACE_SPREAD
		for k: String in sliders:
			_spread[k] = float(sliders[k]["sd"]) / maxf(float(sliders[k]["range"]), 1e-6)
	return float(_spread.get(key, FACE_SPREAD))


static func _mod_keys(tab: String) -> Array:
	var keys: Array = []
	for entry: Dictionary in CharacterAppearance.catalogue()["modifiers"]:
		if String(entry["tab"]) == tab:
			keys.append("mod:" + String(entry["key"]))
	return keys


static func _axis_shares(id: String) -> Dictionary:
	for axis: Array in FaceAxes.axes():
		if String(axis[0]) == id:
			return axis[2]
	return {}


static func _origins_locked(locks: Dictionary) -> bool:
	for i in CharacterAppearance.ORIGINS:
		if locks.get("origin:%d" % i, false):
			return true
	return false


static func _is_face_slider(key: String) -> bool:
	var id: int = CharacterAppearance.modifier_id(key.substr(4))
	return id != -1 and FACE_TABS.has(String(CharacterAppearance.catalogue()["modifiers"][id]["tab"]))


## A catalogue face slider drawn around the drawn face's own value (random() leaves most at 0): a normal draw of
## its spread in real faces, kept where the creator would stop a drag from [param current]'s value.
static func _draw_face_slider(current: CharacterAppearance, out: CharacterAppearance, key: String,
		rng: RandomNumberGenerator) -> void:
	var id: int = CharacterAppearance.modifier_id(key.substr(4))
	# A face within the budget is drawn afresh in the room left; one past it (saved before the limits) may only shrink.
	var past: bool = CreatorLimits.load_of(current) > CreatorLimits.budget() + CreatorLimits.EPSILON
	_set_slider(out, id, float(out.modifiers.get(id, 0.0)) + rng.randfn(0.0, face_spread(key.substr(4))),
			float(current.modifiers.get(id, 0.0)) if past else 0.0)


## Slider [param id] of [param out] set to [param v], within its travel and where the creator would stop a drag
## from [param from] (CreatorLimits.max_move: the face's budget, a body slider's cap; a face already past the budget,
## saved before it, may still move back towards 0), on the stored grid.
static func _set_slider(out: CharacterAppearance, id: int, v: float, from: float) -> void:
	var entry: Dictionary = CharacterAppearance.catalogue()["modifiers"][id]
	v = clampf(v, 0.0 if entry["unipolar"] else -1.0, 1.0)
	if is_zero_approx(from):
		out.modifiers.erase(id)
	else:
		out.modifiers[id] = from
	v = CreatorLimits.max_move(out, id, v)
	v = signf(v) * floorf(absf(v) * CreatorLimits.STEPS + 0.5) / CreatorLimits.STEPS
	if not is_zero_approx(v):
		out.modifiers[id] = v


## The locked keys among [param keys] (and every locked key, for all of them) taken back from [param current]:
## after a style, a garment row or an axis moved them along with what was drawn.
static func _restore(current: CharacterAppearance, out: CharacterAppearance, locks: Dictionary, keys: Array) -> void:
	var axes: Array = []
	for k: String in keys:
		if locks.get(k, false):
			if k.begins_with("axis:"):
				axes.append(k)  # last: on the sliders as the other keys left them
			else:
				copy(current, out, k)
	for k: String in axes:
		copy(current, out, k)


static func _finish(out: CharacterAppearance) -> void:
	out.garments = CharacterAppearance.dressed(out.garments, "female" if out.is_female() else "male")
	out.canonicalise()
