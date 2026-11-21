class_name FaceTypes
extends RefCounted

## European faces as FFHQ's photos show them, per sex and age band (european_face_types.json, written by
## tools/character/face_survey/face_types.py from ~20 000 European adults' photos fitted as the creator's "From photos"
## fits them): per trait (nose, mouth, eyes, brows, jaw, the face's outline) a few TYPES, each the likeliest face with
## that trait's mean shape among the photos of its group, and per age band its most frequent types, until they cover
## 70 % of the band's photos (3 or 4: the rarest, the farthest from the mean, stay out), with their shares.
## A random European face draws one type per trait by those shares, adds them to the sex's mean face, then draws
## FLAME's directions around them with what spread remains (the types already take some of it).
##
## Never named by an autoload (it loads CharacterAppearance's catalogue): loaded where a random look is drawn.

const PATH: String = "res://assets/_universe/characters/human/european_face_types.json"
const FLAME_PREFIX: String = "FLAME_Identity_"
## How strongly the types are applied, on top of the file's gain: 1 = as the photos measured them. Fits to photos are
## held by their prior and come out flatter than the faces (face_types.py "shrink": their shapes spread 0.3-0.5 of
## FLAME's random faces'): above 1 tells the types more boldly. Reversible: only random looks use it.
const STRENGTH: float = 1.0

static var _data: Dictionary = {}


static func data() -> Dictionary:
	if _data.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH)) if FileAccess.file_exists(PATH) else null
		_data = parsed if parsed is Dictionary else {"": {}}
	return _data


## Whether the types are there (the file was generated).
static func available() -> bool:
	return data().has("female") and data().has("male")


## Index into [param bands] (each {from, to, types}) of the band holding [param years].
static func band_at(bands: Array, years: float) -> int:
	for b in bands.size():
		if years < float(bands[b]["to"]) + 1.0:
			return b
	return bands.size() - 1


## The type drawn from [param band] ({types: [[index, share]...]}) for a uniform [param roll] in 0..1.
static func pick(band: Dictionary, roll: float) -> int:
	var types: Array = band["types"]
	var below: float = 0.0
	for entry: Array in types:
		below += float(entry[1])
		if roll < below:
			return int(entry[0])
	return int(types[types.size() - 1][0])


## The face of a European [param female] of [param years]: stored slider values by key (the sex's mean face, one type
## per trait drawn with [param u] (uniform 0..1), FLAME's directions drawn around them with [param normal] (a standard
## normal)), and the types drawn, per trait, in "picked". Empty without the file.
static func face(female: bool, years: float, u: Callable, normal: Callable) -> Dictionary:
	if not available():
		return {}
	var sex: Dictionary = data()["female" if female else "male"]
	var values: Dictionary = {}
	for key: String in sex["mean"]:
		values[key] = float(sex["mean"][key])
	var gain: float = float(sex.get("gain", 1.0)) * STRENGTH
	var picked: Dictionary = {}
	for feature: String in data()["traits"]:
		var entry: Dictionary = sex["traits"][feature]
		var bands: Array = entry["bands"]
		var t: int = pick(bands[band_at(bands, years)], u.call())
		picked[feature] = t
		var delta: Dictionary = entry["types"][t]["delta"]
		for key: String in delta:
			values[key] = float(values.get(key, 0.0)) + gain * float(delta[key])
	var noise: Dictionary = sex["noise"]
	for k in noise.size():
		var key: String = "%s%02d" % [FLAME_PREFIX, k]
		values[key] = float(values.get(key, 0.0)) + normal.call() * float(noise.get(key, 0.0))
	return {"values": values, "picked": picked}
