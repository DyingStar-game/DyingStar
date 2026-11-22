class_name HumanMacros
extends RefCounted

## Which targets a body's macro sliders turn on, and how strongly.
##
## The Vitruvian body has one shape key per trait, each simply weighted (MakeHuman, the first base, mixed
## hundreds of level combinations):
##
##   gender   0 = woman .. 0.5 = the neutral body .. 1 = man     -> Gender_Female / Gender_Male
##   age      0 = 18 years .. 1 = 90 years                        -> Age_Old, from 30 years on
##   origins  one weight per origin shape (HumanBank.macro_config "origins"), their sum kept <= 1
##   height   0..1 = MIN_STATURE..MAX_STATURE of the base body's height: a plain scale of the whole body,
##            applied by HumanBuilder (stature()), not a target
##
## The other body and face sliders are catalogue sliders, one shape key each (CharacterAppearance).

const MACROS: Array[String] = ["gender", "age", "height"]
## Default slider values: the neutral adult.
const DEFAULTS: Dictionary = {"gender": 0.5, "age": 0.1, "height": 0.5}
const MIN_YEARS: float = 18.0
const MAX_YEARS: float = 90.0
## Age (years) at which the old-age shape starts, and at which it is complete.
const OLD_FROM_YEARS: float = 30.0
const OLD_AT_YEARS: float = 85.0
## The body's height against the base body's (1.75 m), at height 0 and 1: 1.57 m .. 1.92 m.
const MIN_STATURE: float = 0.9
const MAX_STATURE: float = 1.1


## What an origin does to a face, beyond the base model's own origin key -- which is timid (2 to 6 mm at
## most, and seven of the twelve are neighbours): per origin, feature sliders (the catalogue's shape keys)
## and how far each is pushed at full weight. Weights go past a slider's own +-1: a face must say where
## it comes from at a glance. Tendencies of a population, not a rule -- a person's own sliders add to them.
## Except the nose's bridge and the eyelids, kept within their sliders' travel: rated by eye (200 random faces,
## 2026-11-16), pushed past it the bridge sank into a groove between the eyes (African, East Asian: 37-47 % of those
## faces rejected for it) or ran out of the forehead like a beak (Middle Eastern: 42 %), the East Asian lids folded
## shut -- where European and Hispanic faces, within it, had none.
## The European mouth and nose are measured (MediaPipe, 80 random European faces against 2 236 frontal neutral adults
## of FFHQ, 2026-11-20): a narrow pinched nose (-2 sd), a narrow mouth (-1.1 sd women, -1.8 men) with a thin
## lower lip, pursed (lips rolled in on a quarter of the faces, 5 % of photos) -- no other origin was. Hence an
## open aperture, fuller lips and a wider mouth.
## The African mouth and the East Asian eyes, measured the same way (2026-11-21: 200 random faces of each against
## FFHQ's frontal neutral photos of that origin, 47-165 per sex, beside the European faces' own gap): the African
## mouth was 1.2-2.2 sd too wide and its lips 1.6-2.1 sd too thick (the lengthened mouth, lips at 1.8), the East Asian
## eyes 1.4 sd too narrow and 2 sd too closed (Eye_Size at -0.6). Hence a mouth of its own length, lips at 0.8, and
## eyes of their own size -- the width made up, half the opening: no shape key opens the lids alone.
const ORIGIN_FEATURES: Dictionary = {
	"Race_African": {
		"Nose_NasalBone_AnteriorNasalAperature": 2.4, "Nose_BridgeProminence": -0.8, "Nose_NasalBone": -0.6,
		"Nose_Potrusion": -1.0, "Nose_Tip_Potrusion": -0.6, "Mouth_Lips_Height": 0.8, "Mouth_Lips_UpperLipDepth": 1.2,
		"Mouth_Lips_BottomLipDepth": 1.3, "Face_Maxilla": 1.1, "Face_Zygomatic_Bone": 0.5,
		"Face_FrontalBone_BrowRidge": -0.4, "Head_BackScalpPotrusion": 0.5, "Head_SideScalpPotrusion": -0.3,
		"Chin_Portrusion": -0.5,
	},
	"Race_EastAsian": {
		"Nose_BridgeProminence": -0.9, "Nose_NasalBone": -0.7, "Nose_Potrusion": -1.2, "Nose_Tip_Potrusion": -0.6,
		"Nose_NasalBone_AnteriorNasalAperature": 0.7, "Face_Zygomatic_Bone": 1.8, "Cheeks_UpperCheek_Bone": 1.3,
		"Face_EyeSocket_Potrusion": 1.2, "Eyes_EyelidsAngle": 0.8, "Eyes_EyelidsCrease": -1.0,
		"Face_FrontalBone_BrowRidge": -1.2, "Head_SideScalpPotrusion": 0.6, "Head_BackScalpPotrusion": -0.6,
		"Face_Maxilla": -0.3, "Mouth_Lips_Height": 0.4, "Jaw_Mandible_GonialAngle": 0.4,
	},
	"Race_White": {
		"Nose_BridgeProminence": 1.2, "Nose_NasalBone": 0.9, "Nose_Potrusion": 1.2, "Nose_Tip_Potrusion": 0.5,
		"Mouth_Lips_Height": 0.4, "Mouth_Lips_Length": 0.8, "Face_FrontalBone_BrowRidge": 0.6,
		"Face_Zygomatic_Bone": -0.5, "Face_Maxilla": -0.6, "Chin_Portrusion": 0.6, "Face_EyeSocket_Potrusion": -0.5,
	},
	"Race_Hispanic": {
		"Nose_BridgeProminence": 0.3, "Nose_NasalBone_AnteriorNasalAperature": 0.9, "Face_Zygomatic_Bone": 1.0,
		"Cheeks_UpperCheek_Bone": 0.6, "Mouth_Lips_Height": 0.8, "Face_FrontalBone_BrowRidge": 0.3,
		"Head_SideScalpPotrusion": 0.4, "Eyes_EyelidsAngle": 0.5, "Nose_Potrusion": -0.3,
	},
	"Race_MiddleEastern": {
		"Nose_BridgeProminence": 1.0, "Nose_NasalBone": 0.8, "Nose_NoseHeight": 0.5, "Nose_NasalAngle": 0.8,
		"Nose_Potrusion": 1.0, "Face_FrontalBone_BrowRidge": 0.9, "Mouth_Lips_Height": 0.5, "Chin_Portrusion": 0.3,
		"Eye_Size": 0.4, "Face_Zygomatic_Bone": -0.2,
	},
	"Race_Bengali": {
		"Nose_BridgeProminence": 0.5, "Nose_NasalBone_AnteriorNasalAperature": 0.5, "Mouth_Lips_Height": 1.0,
		"Eye_Size": 0.6, "Jaw_Mandible": -0.5, "Head_SideScalpPotrusion": 0.4, "Chin_Portrusion": -0.3,
	},
	"Race_Tamil": {
		"Nose_BridgeProminence": 0.3, "Nose_NasalBone_AnteriorNasalAperature": 1.2, "Mouth_Lips_Height": 1.5,
		"Mouth_Lips_BottomLipDepth": 0.8, "Face_Maxilla": 0.5, "Eye_Size": 0.6, "Jaw_Mandible": -0.4,
	},
	"Race_Punjabi": {
		"Nose_BridgeProminence": 1.0, "Nose_NasalBone": 0.8, "Nose_NoseHeight": 0.3, "Face_FrontalBone_BrowRidge": 0.6,
		"Mouth_Lips_Height": 0.5, "Eye_Size": 0.4, "Chin_Portrusion": 0.3,
	},
	"Race_Marathi": {
		"Nose_BridgeProminence": 0.7, "Nose_NasalBone_AnteriorNasalAperature": 0.4, "Mouth_Lips_Height": 0.8,
		"Eye_Size": 0.5, "Jaw_Mandible": -0.4, "Face_Zygomatic_Bone": -0.2,
	},
	"Race_Telegu": {
		"Nose_BridgeProminence": 0.4, "Nose_NasalBone_AnteriorNasalAperature": 0.8, "Mouth_Lips_Height": 1.1,
		"Face_Zygomatic_Bone": 0.4, "Eye_Size": 0.5, "Jaw_Mandible": -0.3,
	},
	"Race_Sinhalese": {
		"Nose_BridgeProminence": 0.5, "Nose_NasalBone_AnteriorNasalAperature": 0.6, "Mouth_Lips_Height": 1.3,
		"Eye_Size": 0.8, "Jaw_Mandible": -0.5, "Chin_Portrusion": -0.2,
	},
	"Race_Kannada": {
		"Nose_BridgeProminence": 0.8, "Nose_NasalBone_AnteriorNasalAperature": 0.5, "Mouth_Lips_Height": 0.9,
		"Eye_Size": 0.5, "Chin_Portrusion": 0.3, "Face_Zygomatic_Bone": 0.2,
	},
}
## Scales every weight of ORIGIN_FEATURES: 0 = the base model's origin keys alone, higher = stronger types.
const ORIGIN_FEATURE_GAIN: float = 1.0


## Age in years of an age slider value.
static func years_of(age: float) -> float:
	return lerpf(MIN_YEARS, MAX_YEARS, clampf(age, 0.0, 1.0))


## The age slider value of an age in years.
static func age_of(years: float) -> float:
	return clampf(inverse_lerp(MIN_YEARS, MAX_YEARS, years), 0.0, 1.0)


## Scale of the whole body for a height slider value.
static func stature(height: float) -> float:
	return lerpf(MIN_STATURE, MAX_STATURE, clampf(height, 0.0, 1.0))


## [[target key, weight]] for the macro sliders (missing ones take DEFAULTS) and the origin weights (in
## the order of config["origins"]).
static func target_stack(config: Dictionary, macros: Dictionary, origins: PackedFloat32Array) -> Array:
	var out: Array = []
	var gender: float = float(macros.get("gender", DEFAULTS["gender"]))
	var female: float = clampf(1.0 - 2.0 * gender, 0.0, 1.0)
	var male: float = clampf(2.0 * gender - 1.0, 0.0, 1.0)
	if female > 0.0:
		out.append([String(config["female"]), female])
	if male > 0.0:
		out.append([String(config["male"]), male])
	var years: float = years_of(float(macros.get("age", DEFAULTS["age"])))
	var old: float = clampf(inverse_lerp(OLD_FROM_YEARS, OLD_AT_YEARS, years), 0.0, 1.0)
	if old > 0.0:
		out.append([String(config["old"]), old])
	var names: Array = config["origins"]
	var total: float = 0.0
	for w in origins:
		total += maxf(w, 0.0)
	var scale: float = 1.0 / total if total > 1.0 else 1.0
	for i in mini(names.size(), origins.size()):
		if origins[i] > 0.0:
			var w: float = origins[i] * scale
			out.append([String(names[i]), w])
			var features: Dictionary = ORIGIN_FEATURES.get(String(names[i]), {})
			for key: String in features:
				out.append([key, features[key] * w * ORIGIN_FEATURE_GAIN])
	return out
