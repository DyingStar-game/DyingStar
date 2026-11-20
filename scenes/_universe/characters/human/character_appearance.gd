class_name CharacterAppearance
extends RefCounted

## What a character looks like: body and face shape, skin, eyes, hair, beard and the garments it wears --
## small enough to travel as one replicated string, and the same bytes on every machine.
##
## The wire form is a versioned byte string in base64url (no padding), 58 bytes plus 2 per face / body
## slider moved off its default and 3 per garment worn (version 7: garments, the GDD's equipment):
##
##   0       version (7)
##   1..3    gender, age, height, u8 (HumanMacros)
##   4..15   origin weights, u8 (HumanMacros: the bank's 12 origin shapes)
##   16..18  skin: tone (0 = lightest .. 1 = darkest), warmth (0.5 = neutral), dimples (0 = none: the byte
##           was reserved and 0 before, so older looks have none)
##   19      eye colour (human_catalogue.json eye_colours)
##   20..24  hair (0 = none, else the style it started from: assets.hair), eumelanin, pheomelanin, grey,
##           length (cut off its tips: 1 since version 4, whose length is the cut's)
##   25..26  eyebrows, eyelashes
##   27..28  beard (0 = none, else the style it started from: assets.beard), length (cut: 1 since v4)
##   29      reserved, 0 (the outfit until version 6: a suit and its shoes, now garments)
##   30..35  skin details (SKIN_DETAILS order): freckles, moles, wrinkles, redness, eye bags, unevenness
##   36..47  the head of hair's settings (HairCut.to_bytes)
##   48..55  the beard's settings (BeardCut.to_bytes)
##   56      N sliders, then N x (slider id u8 = position in the catalogue, value s8 / 127)
##   then    G garments, then G x (garment u16 little-endian = position in the catalogue's "garments", tint u8:
##           0 = its own colours)
##
## Versions 6 (no garments: the outfit at byte 29, worn as the garments the catalogue lists for it), 5 (a cut of
## 11 bytes: no flyaways, beard at 47, N at 55), 4 (10 bytes: nor a low hairline), 3 (no hair or beard settings, N
## at 36) and 2 (nor skin details, N at 30) are still read: before version 4 the hair and the beard are their
## style's settings (HairCut / BeardCut.PRESETS) at the length they were cut to, the details their defaults.
##
## Every value lives on that byte grid, and an appearance is always kept CANONICAL (canonicalise): values
## quantised and in range, choices that exist, sliders sorted by id with the zeros dropped. So
## decode(encode(a)) == a, and two machines given the same look agree on its hashes -- shape_hash keys
## the baked mesh cache (colours excluded: they never rebuild a mesh), look_hash everything.
##
## Lists are positions in the append-only catalogue (human_catalogue.json, generated with the bank):
## only appending keeps saved characters valid. This class reads that small file, never the bank, so the
## dedicated server can validate appearances. Every body is an adult: the age slider starts at 18 years.

const VERSION: int = 7
const HEADER_BYTES: int = 57
## Garments a look may wear at once (a dozen make a full outfit with gloves, a coat and a helmet).
const MAX_GARMENTS: int = 24
## GDD zones a look always wears something on: the torso and the legs. There is no underwear yet, so a look with
## nothing there would be naked; canonicalise puts on what is missing (dressed). Underwear (layer 0) will meet the
## rule too, and be what a bare look gets: the lowest layer is put on first.
const COVERED_ZONES: Array = ["3", "8"]
## Where a random look draws its garments, in order: [GDD zone, the layers drawn there, chance, only when nothing
## worn yet covers the zone]. Clothing on the torso and legs (a suit covers both), shoes, sometimes a jacket or a coat,
## rarely gloves or a hat.
const RANDOM_GARMENT_PLACES: Array = [["3", [1], 1.0, true], ["8", [1], 1.0, true], ["9", [1, 2], 0.97, true],
		["3", [2, 3], 0.25, false], ["5", [1, 2], 0.08, true], ["1", [1, 2, 3], 0.1, true]]
## Versions 5 and 4: a cut of HairCut.V5_BYTES / V4_BYTES, the beard's settings right after it, the slider count
## at the header's last byte.
const V5_HEADER_BYTES: int = 56
const V4_HEADER_BYTES: int = 55
## Version 3: no hair settings (its slider count is at byte 36).
const V3_HEADER_BYTES: int = 37
## Version 2: nor skin details (its slider count is at byte 30).
const V2_HEADER_BYTES: int = 31
## Where the hair's settings start (HairCut.BYTES of them).
const HAIR_CUT_AT: int = 36
## Where the beard's settings start (BeardCut.BYTES of them).
const BEARD_CUT_AT: int = 48
## The skin's details, each 0..1, in their byte order (30..35).
## Share of people with cheek dimples (random()).
const DIMPLE_CHANCE: float = 0.25
const SKIN_DETAILS: Array[StringName] = [&"freckles", &"moles", &"wrinkles", &"redness", &"eye_bags", &"unevenness"]
const ORIGINS: int = 12
## Sliders an appearance may move (the creator offers ~100; nobody needs them all moved at once).
const MAX_MODIFIERS: int = 96
## Positions of three origins in the catalogue's list (append-only), which a random look treats apart.
const ORIGIN_AFRICAN: int = 0
const ORIGIN_EAST_ASIAN: int = 1
const ORIGIN_WHITE: int = 2
## Sliders carried over from FLAME 2023 Open (tools/character/flame): each shape key is one standard deviation of
## real faces along one of FLAME's identity directions; a slider's full travel reaches FLAME_RANGE of them.
const FLAME_PREFIX: String = "FLAME_Identity_"
const FLAME_RANGE: float = 3.0
## A random face is FLAME's alone: every one of its directions drawn as real faces spread along them (1 sd each),
## no catalogue face slider. Drawn at random, those sliders pouted the lips, rounded the eyes into a doll's and
## puffed the cheeks -- where faces fitted to photos, FLAME's alone, looked real (rated by eye against random
## European faces, 2026-11-20). Directions past the first 20 add little, but what they add is real.
const RANDOM_FLAME_DIRECTIONS: int = 50
const RANDOM_FLAME_SPREAD: float = 1.0
## Expression lines with age: none before WRINKLES_FROM_YEARS, full at WRINKLES_FULL_AT_YEARS, straight between.
## Measured on 4 073 adult faces of FFHQ without make-up (forehead lines and crow's feet, face_survey
## skin_measure.py): their median rises nearly linearly from the mid-twenties and keeps rising past 60.
const WRINKLES_FROM_YEARS: float = 22.0
const WRINKLES_FULL_AT_YEARS: float = 70.0
## Sliders a random look leaves alone: a lopsided face or a cleft chin is a choice, not a draw; and the skull's
## bumps, which a head of hair -- one rigid mesh carried by an affine fit (HairStrands.fit) -- cannot follow.
const RANDOM_LEFT_ALONE: Array[String] = ["Generic_Assymetry", "Chin_ChinCleft", "Mouth_NoTeeth", "Head_TopScalpPotrusion",
		"Head_SideScalpPotrusion", "Head_BackScalpPotrusion"]
const MAX_BYTES: int = HEADER_BYTES + 2 * MAX_MODIFIERS + 1 + 3 * MAX_GARMENTS
const CATALOGUE_PATH: String = "res://assets/_universe/characters/human/human_catalogue.json"
## What real faces do with some sliders (tools/character/face_survey/stats.py, from FFHQ's adults): how far
## a slider's full travel reaches, and how faces spread around the neutral per sex.
const FACE_STATS_PATH: String = "res://assets/_universe/characters/human/face_stats.json"
## What hair real people wear (tools/character/face_survey/hair_stats.py, from FFHQ's adults): per sex and
## age band, families of heads of hair and how often each is worn; beard and baldness rates.
const HAIR_STATS_PATH: String = "res://assets/_universe/characters/human/hair_stats.json"
## The hair settings hair_stats.json first had (length .. crown_bald): drawn from the look's own numbers; later
## ones (low_line) from their own, so that a new field leaves every NPC's face as it was.
const FIRST_HAIR_FIELDS: int = 8
## Skin tone a body of each origin tends to (catalogue "origins" order), for random looks.
const ORIGIN_TONES: Array[float] = [0.85, 0.3, 0.12, 0.4, 0.4, 0.6, 0.7, 0.5, 0.55, 0.6, 0.65, 0.6]

var macros: Dictionary = HumanMacros.DEFAULTS.duplicate()
## Weight of each origin shape (catalogue "origins" order), 0..1.
var origins := PackedFloat32Array()
## 0 = the lightest skin .. 1 = the darkest.
var skin_tone: float = 0.25
## 0.5 = neutral; lower = cooler / pinker, higher = warmer / more olive.
var skin_warmth: float = 0.5
var eye_colour: int = 0
var hair: int = 0
var hair_eumelanin: float = 0.6
var hair_pheomelanin: float = 0.1
var hair_grey: float = 0.0
## Share of the style's length kept, cutting its tips (0.4 at 0 .. all at 1): 1 since version 4, whose
## hair length is the cut's own (cut.length).
var hair_length: float = 1.0
## The head of hair's settings (HairGroom grows it), worn when [member hair] is not 0.
var cut: HairCut = HairCut.new()
var eyebrows: int = 0
var eyelashes: int = 0
var beard: int = 0
## Share of the beard's length kept (0.4 at 0 .. all at 1): 1 since version 4 (beard_cut.length).
var beard_length: float = 1.0
## The beard's settings (BeardGroom grows it), worn when [member beard] is not 0.
var beard_cut: BeardCut = BeardCut.new()
## The garments worn: [position in the catalogue's "garments", tint 0..255 (0 = its own colours)] each. Kept
## canonical: known garments that can be worn together (GarmentRules), sorted by position.
var garments: Array = []
## Skin details, 0..1 (human_skin.gdshader): freckles; moles; expression lines (the old-age wrinkles come
## with the age); redness of cheeks, nose and ears; shadows under the eyes; an uneven, blotchy tone.
var freckles: float = 0.0
var moles: float = 0.3
var wrinkles: float = 0.2
var redness: float = 0.3
var eye_bags: float = 0.3
var unevenness: float = 0.3
## Cheek dimples, 0 (none) .. 1 (deep): they show as the face smiles (human_skin_detail, face_motion).
var dimples: float = 0.0
## Slider id -> value (-1..1, or 0..1 for a one-sided slider).
var modifiers: Dictionary = {}

static var _catalogue: Dictionary = {}
static var _modifier_ids: Dictionary = {}  # slider key -> id
static var _face_stats: Dictionary = {}
static var _hair_stats: Dictionary = {}


func _init() -> void:
	origins.resize(ORIGINS)


# --- catalogue -----------------------------------------------------------------------------------------

## The runtime catalogue (sliders, asset choices, eye colours, origins), read once.
static func catalogue() -> Dictionary:
	if _catalogue.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOGUE_PATH))
		_catalogue = parsed if parsed is Dictionary else {"modifiers": [], "assets": {}, "eye_colours": [], "origins": []}
		for i in (_catalogue["modifiers"] as Array).size():
			_modifier_ids[_catalogue["modifiers"][i]["key"]] = i
	return _catalogue


## Per slider key, what real faces do with it: {range, sd, female, male} (face_stats.json); empty when unknown.
static func face_stats() -> Dictionary:
	if _face_stats.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(FACE_STATS_PATH)) \
				if FileAccess.file_exists(FACE_STATS_PATH) else null
		_face_stats = parsed["sliders"] if parsed is Dictionary and parsed.has("sliders") else {"": {}}
	return _face_stats


## hair_stats.json, or {} without it (random looks then keep their style's settings).
static func hair_stats() -> Dictionary:
	if _hair_stats.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(HAIR_STATS_PATH)) \
				if FileAccess.file_exists(HAIR_STATS_PATH) else null
		_hair_stats = parsed if parsed is Dictionary and parsed.has("hair") else {"none": true}
	return {} if _hair_stats.has("none") else _hair_stats


## How far a slider's full travel reaches, in its shape key's units: real faces go past what one shape key
## at full weight makes for some features (the mouth's width, the jaw's angle...).
static func slider_range(key: String) -> float:
	if key.begins_with(FLAME_PREFIX):
		return FLAME_RANGE
	return float((face_stats().get(key, {}) as Dictionary).get("range", 1.0))


## Number of choices of an asset kind (hair, eyebrows, eyelashes...).
static func choice_count(kind: String) -> int:
	return (catalogue()["assets"].get(kind, []) as Array).size()


## The catalogue's garments: {id, zones, support, layer, access, hides, material, gender} each, in their
## append-only order (a look stores positions in it).
static func garment_entries() -> Array:
	return catalogue().get("garments", [])


## Position of a garment in the catalogue from its id, or -1.
static func garment_index(id: String) -> int:
	var entries: Array = garment_entries()
	for i in entries.size():
		if String(entries[i]["id"]) == id:
			return i
	return -1


## The garments an outfit of version 6 and before is worn as (assets.outfit[slot].garments), as positions.
static func outfit_garments(slot: int) -> Array:
	var outfits: Array = catalogue()["assets"].get("outfit", [])
	var out: Array = []
	if slot < 0 or slot >= outfits.size():
		return out
	for id: Variant in (outfits[slot] as Dictionary).get("garments", []):
		var i: int = garment_index(String(id))
		if i != -1:
			out.append(i)
	return out


## Id of a slider from its catalogue key, or -1.
static func modifier_id(key: String) -> int:
	catalogue()
	return _modifier_ids.get(key, -1)


# --- wire form -----------------------------------------------------------------------------------------

func to_bytes() -> PackedByteArray:
	canonicalise()
	var out := PackedByteArray()
	out.resize(HEADER_BYTES)
	out[0] = VERSION
	for i in HumanMacros.MACROS.size():
		out[1 + i] = _u8(macros[HumanMacros.MACROS[i]])
	for i in ORIGINS:
		out[4 + i] = _u8(origins[i])
	out[16] = _u8(skin_tone)
	out[17] = _u8(skin_warmth)
	out[18] = _u8(dimples)
	out[19] = eye_colour
	out[20] = hair
	out[21] = _u8(hair_eumelanin)
	out[22] = _u8(hair_pheomelanin)
	out[23] = _u8(hair_grey)
	out[24] = _u8(hair_length)
	out[25] = eyebrows
	out[26] = eyelashes
	out[27] = beard
	out[28] = _u8(beard_length)
	out[29] = 0
	for i in SKIN_DETAILS.size():
		out[30 + i] = _u8(get(SKIN_DETAILS[i]))
	var cut_bytes: PackedByteArray = cut.to_bytes()
	for i in HairCut.BYTES:
		out[HAIR_CUT_AT + i] = cut_bytes[i]
	var beard_bytes: PackedByteArray = beard_cut.to_bytes()
	for i in BeardCut.BYTES:
		out[BEARD_CUT_AT + i] = beard_bytes[i]
	var ids: Array = modifiers.keys()
	ids.sort()
	out[HEADER_BYTES - 1] = ids.size()
	for id: int in ids:
		out.append(id)
		out.append(_s8(modifiers[id]) & 0xFF)
	out.append(garments.size())
	for g: Array in garments:
		out.append(int(g[0]) & 0xFF)
		out.append((int(g[0]) >> 8) & 0xFF)
		out.append(int(g[1]))
	return out


## The appearance as its replicated string (base64url, no padding).
func encode() -> String:
	return Marshalls.raw_to_base64(to_bytes()).replace("+", "-").replace("/", "_").trim_suffix("=").trim_suffix("=")


## An appearance from its bytes, canonicalised; null when they are not a valid appearance (another
## version included: a look of the first body does not describe this one).
static func from_bytes(data: PackedByteArray) -> CharacterAppearance:
	if data.size() < V2_HEADER_BYTES or data.size() > MAX_BYTES or not data[0] in [VERSION, 6, 5, 4, 3, 2]:
		return null
	var header: int = {VERSION: HEADER_BYTES, 6: HEADER_BYTES, 5: V5_HEADER_BYTES, 4: V4_HEADER_BYTES,
			3: V3_HEADER_BYTES, 2: V2_HEADER_BYTES}[data[0]]
	if data.size() < header:
		return null
	var n: int = data[header - 1]
	var g_at: int = header + 2 * n
	if data[0] >= 7:
		if data.size() < g_at + 1 or data.size() != g_at + 1 + 3 * data[g_at]:
			return null
	elif data.size() != g_at:
		return null
	var a := CharacterAppearance.new()
	for i in HumanMacros.MACROS.size():
		a.macros[HumanMacros.MACROS[i]] = data[1 + i] / 255.0
	for i in ORIGINS:
		a.origins[i] = data[4 + i] / 255.0
	a.skin_tone = data[16] / 255.0
	a.skin_warmth = data[17] / 255.0
	a.dimples = data[18] / 255.0
	a.eye_colour = data[19]
	a.hair = data[20]
	a.hair_eumelanin = data[21] / 255.0
	a.hair_pheomelanin = data[22] / 255.0
	a.hair_grey = data[23] / 255.0
	a.hair_length = data[24] / 255.0
	a.eyebrows = data[25]
	a.eyelashes = data[26]
	a.beard = data[27]
	a.beard_length = data[28] / 255.0
	if data[0] >= 7:
		for k in data[g_at]:
			var at: int = g_at + 1 + 3 * k
			a.garments.append([data[at] | (data[at + 1] << 8), data[at + 2]])
	else:  # the outfit, as the garments it is now
		for i: int in outfit_garments(data[29]):
			a.garments.append([i, 0])
	if data[0] >= 3:
		for i in SKIN_DETAILS.size():
			a.set(SKIN_DETAILS[i], data[30 + i] / 255.0)
	else:
		a.skin_defaults()
	if data[0] >= 4:
		var cut_bytes: int = {VERSION: HairCut.BYTES, 6: HairCut.BYTES, 5: HairCut.V5_BYTES, 4: HairCut.V4_BYTES}[data[0]]
		var beard_at: int = HAIR_CUT_AT + cut_bytes
		a.cut = HairCut.from_bytes(data.slice(HAIR_CUT_AT, HAIR_CUT_AT + cut_bytes))
		a.beard_cut = BeardCut.from_bytes(data.slice(beard_at, beard_at + BeardCut.BYTES))
	else:  # the styles it wore, as long as they were cut
		a.cut = a.style_cut(a.hair, a.hair_length)
		a.hair_length = 1.0
		a.beard_cut = a.beard_style_cut(a.beard, a.beard_length)
		a.beard_length = 1.0
	for k in n:
		var raw: int = data[header + 2 * k + 1]
		a.modifiers[int(data[header + 2 * k])] = (raw - 256 if raw > 127 else raw) / 127.0
	a.canonicalise()
	return a


## An appearance from its replicated string; null when it is not one (bad characters, size, version).
static func decode(text: String) -> CharacterAppearance:
	# Unpadded base64 is never 1 more than a multiple of 4 long; refused here, the engine's decoder would
	# log an error for it -- for every hostile request a server gets.
	if text.is_empty() or text.length() > (MAX_BYTES * 4 + 2) / 3 + 1 or text.length() % 4 == 1:
		return null
	for c in text:
		if not (c >= "A" and c <= "Z" or c >= "a" and c <= "z" or c >= "0" and c <= "9" or c == "-" or c == "_"):
			return null
	var b64: String = text.replace("-", "+").replace("_", "/")
	while b64.length() % 4 != 0:
		b64 += "="
	return from_bytes(Marshalls.base64_to_raw(b64))


## Put every value on the byte grid and in range: choices that exist, sliders known, sorted, non-zero
## and within their side. Idempotent.
func canonicalise() -> void:
	var cat: Dictionary = catalogue()
	for m in HumanMacros.MACROS:
		macros[m] = _q(float(macros.get(m, HumanMacros.DEFAULTS[m])))
	origins.resize(ORIGINS)
	for i in ORIGINS:
		origins[i] = _q(origins[i])
	skin_tone = _q(skin_tone)
	skin_warmth = _q(skin_warmth)
	dimples = _q(dimples)
	eye_colour = _slot(eye_colour, (cat["eye_colours"] as Array).size())
	hair = _slot(hair, choice_count("hair"))
	hair_eumelanin = _q(hair_eumelanin)
	hair_pheomelanin = _q(hair_pheomelanin)
	hair_grey = _q(hair_grey)
	hair_length = _q(hair_length)
	cut = HairCut.from_bytes(cut.to_bytes()) if cut != null else HairCut.new()
	beard_cut = BeardCut.from_bytes(beard_cut.to_bytes()) if beard_cut != null else BeardCut.new()
	eyebrows = _slot(eyebrows, choice_count("eyebrows"))
	eyelashes = _slot(eyelashes, choice_count("eyelashes"))
	beard = _slot(beard, choice_count("beard"))
	beard_length = _q(beard_length)
	garments = dressed(garments, "female" if is_female() else "male")
	for detail in SKIN_DETAILS:
		set(detail, _q(float(get(detail))))
	var sliders: Array = cat["modifiers"]
	var clean: Dictionary = {}
	var ids: Array = modifiers.keys()
	ids.sort()
	for id in ids:
		if typeof(id) != TYPE_INT or id < 0 or id >= sliders.size() or id > 255:
			continue
		var value: float = clampf(float(modifiers[id]), 0.0 if sliders[id]["unipolar"] else -1.0, 1.0)
		var s: int = _s8(value)
		if s != 0 and clean.size() < MAX_MODIFIERS:
			clean[id] = s / 127.0
	modifiers = clean


func duplicate_appearance() -> CharacterAppearance:
	return from_bytes(to_bytes())


func equals(other: CharacterAppearance) -> bool:
	return other != null and to_bytes() == other.to_bytes()


# --- hashes --------------------------------------------------------------------------------------------

## Hash of everything that changes the baked mesh: shape sliders, origins, and the worn meshes (hair and
## its length, eyebrows, eyelashes, beard and its length, the garments). Colours are left out -- the skin's,
## the hair's, the garments' tints: they never rebuild a mesh.
func shape_hash() -> int:
	var b: PackedByteArray = to_bytes()
	var shape := PackedByteArray()
	shape.append_array(b.slice(1, 16))
	shape.append(b[20])
	shape.append_array(b.slice(24, 30))
	shape.append_array(b.slice(HAIR_CUT_AT, BEARD_CUT_AT + BeardCut.BYTES))
	# the sliders (the skin details are colours: no new mesh), then the garments without their tints
	var g_at: int = HEADER_BYTES + 2 * b[HEADER_BYTES - 1]
	shape.append_array(b.slice(HEADER_BYTES - 1, g_at + 1))
	for k in b[g_at]:
		shape.append_array(b.slice(g_at + 1 + 3 * k, g_at + 3 + 3 * k))
	return fnv1a(shape)


## Hash of the whole look.
func look_hash() -> int:
	return fnv1a(to_bytes())


## 32-bit FNV-1a: the same on every platform (plain integer arithmetic inside 64 bits).
static func fnv1a(data: PackedByteArray) -> int:
	var h: int = 0x811C9DC5
	for byte in data:
		h = ((h ^ byte) * 0x01000193) & 0xFFFFFFFF
	return h


# --- what the builder reads ----------------------------------------------------------------------------

## [[target key, weight]] of the face and body sliders: each is one shape key, weighted by its value.
func modifier_stack() -> Array:
	var sliders: Array = catalogue()["modifiers"]
	var out: Array = []
	var ids: Array = modifiers.keys()
	ids.sort()
	for id: int in ids:
		if id < sliders.size():
			var key := String(sliders[id]["key"])
			out.append([key, float(modifiers[id]) * slider_range(key)])
	return out


## Age in years.
func years() -> float:
	return HumanMacros.years_of(macros["age"])


func is_female() -> bool:
	return macros["gender"] < 0.5


## Tint multiplied over the skin texture: the skin tone, and its warmth.
func skin_tint() -> Color:
	var dark := Color(0.2, 0.11, 0.07)
	var c: Color = Color.WHITE.lerp(dark, pow(skin_tone, 1.3))
	var w: float = skin_warmth - 0.5
	return Color(c.r * (1.0 + w * 0.1), c.g * (1.0 + w * 0.02), c.b * (1.0 - w * 0.3))


## The iris colour of each catalogue eye colour (sRGB), in "eye_colours" order: an albedo, as dark as an iris
## is. From 2 582 FFHQ eyes (face_survey/eye_measure.py): irises gather in a few families -- dark brown, amber,
## hazel, grey-blue, blue -- far less saturated than painted eyes, ~0.06 (brown) to ~0.2 (blue) as bright as
## the white beside them; their colour is the measured one against the white, a little stronger (a photo dulls it).
const EYE_TINTS: Array[Color] = [
	Color(0.274, 0.128, 0.076),
	Color(0.337, 0.185, 0.100),
	Color(0.280, 0.253, 0.150),
	Color(0.247, 0.279, 0.251),
	Color(0.240, 0.294, 0.337),
	Color(0.304, 0.342, 0.381),
	Color(0.168, 0.242, 0.300),
	Color(0.286, 0.296, 0.305),
	Color(0.352, 0.370, 0.392),
]


## The iris colour (sRGB).
func eye_tint() -> Color:
	return EYE_TINTS[clampi(eye_colour, 0, EYE_TINTS.size() - 1)]


## The head of hair as HairGroom grows it, or null for none.
func hair_cut() -> HairCut:
	if hair == 0:
		return null
	var grown := HairCut.from_bytes(cut.to_bytes())
	grown.round_line = is_female()
	return grown


## The beard as BeardGroom grows it, or null for none.
func beard_grown() -> BeardCut:
	return beard_cut if beard > 0 else null


## The settings of beard style [param slot] (assets.beard: BeardCut.PRESETS) with [param kept] of its
## length kept (beard_length: 0.4 at 0 .. all at 1).
func beard_style_cut(slot: int, kept: float = 1.0) -> BeardCut:
	var styles: Array = catalogue()["assets"].get("beard", [])
	if slot <= 0 or slot >= styles.size():
		return BeardCut.new()
	var out: BeardCut = BeardCut.preset(String(styles[slot]["id"]))
	var metres: float = out.hair_length() * lerpf(0.4, 1.0, kept)
	out.length = clampf(pow(maxf(metres - 0.0015, 0.0) / 0.12, 1.0 / 1.6), 0.0, 1.0)
	return out


## The settings of hair style [param slot] (assets.hair: HairCut.PRESETS) with [param kept] of its length
## kept (hair_length: 0.4 at 0 .. all at 1).
func style_cut(slot: int, kept: float = 1.0) -> HairCut:
	var styles: Array = catalogue()["assets"].get("hair", [])
	if slot <= 0 or slot >= styles.size():
		return HairCut.new()
	var out: HairCut = HairCut.preset(String(styles[slot]["id"]))
	out.set_top_length(out.top_length() * lerpf(0.4, 1.0, kept))
	return out


## Hair colour from its pigments: eumelanin (blond -> black), pheomelanin (red), grey (age).
func hair_colour() -> Color:
	# Blond to dark at FFHQ's chroma and hue for each lightness (hair_measure.py colour, 5 513 adults; chroma 18 at
	# L 64 hue 68 down to 6 at L 10 hue 45), the lightness along eumelanin kept: the old golden ends rendered 1.5-2.8x
	# as saturated, at hue 79 whatever the shade.
	var blond := Color(0.718, 0.628, 0.56)
	var dark := Color(0.047, 0.028, 0.022)
	# Copper, not carrot: FFHQ's reddest hair (top 5 % chroma, hair_measure.py) is chroma 36 at hue 59 (Lab), 44 at
	# its 99th percentile; the old (0.55, 0.16, 0.05) rendered 50 at hue 41 (a render saturates hair ~1.27x its albedo).
	# With eumelanin the red darkens to auburn (FFHQ's dark chromatic hair, L < 35: chroma 25 at hue 53, a quarter
	# under 45) rather than through golden brown, which every dark red was (hue 64-67).
	var red := Color(0.467, 0.276, 0.142).lerp(Color(0.326, 0.157, 0.158), hair_eumelanin)
	var c: Color = blond.lerp(dark, pow(hair_eumelanin, 0.7))
	c = c.lerp(red, hair_pheomelanin * (1.0 - hair_eumelanin * 0.4))
	return c.lerp(Color(0.72, 0.71, 0.69), hair_grey)


## The expression lines of a typical face of [param age] years (0..1).
static func wrinkles_at(age: float) -> float:
	return clampf((age - WRINKLES_FROM_YEARS) / (WRINKLES_FULL_AT_YEARS - WRINKLES_FROM_YEARS), 0.0, 1.0)


## Skin details that suit the body as it is (age, tone): a look made before they existed, a preset.
func skin_defaults() -> void:
	var age: float = years()
	freckles = 0.0
	moles = 0.3
	wrinkles = wrinkles_at(age)
	redness = 0.35 * (1.0 - skin_tone * 0.7)
	eye_bags = 0.2 + 0.4 * clampf((age - 30.0) / 40.0, 0.0, 1.0)
	unevenness = 0.3


# --- random looks --------------------------------------------------------------------------------------

## A plausible adult, the same for the same seed on every machine (integer generator, no transcendental
## maths in what is stored): who a non-player character or a player without a saved look appears as.
static func random(seed_value: int) -> CharacterAppearance:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var u := func() -> float: return float(rng.randi() & 0xFFFFFF) / 16777216.0
	var bell := func(lo: float, hi: float) -> float: return lo + (hi - lo) * (u.call() + u.call() + u.call()) / 3.0
	var a := CharacterAppearance.new()
	var female: bool = u.call() < 0.5
	a.macros["gender"] = bell.call(0.0, 0.2) if female else bell.call(0.8, 1.0)
	a.macros["age"] = HumanMacros.age_of(18.0 + 55.0 * u.call() * u.call() + 4.0 * u.call())
	a.macros["height"] = bell.call(0.15, 0.7) if female else bell.call(0.35, 0.9)
	# One origin, plainly (its features are what make a face African, East Asian, European...), a quarter of
	# the time mixed with a little of another. The six broad groups are as likely: the seven South Asian
	# origins of the base model share one draw.
	var group: int = rng.randi() % 6
	var main: int = group if group < 5 else 5 + rng.randi() % (ORIGINS - 5)
	a.origins[main] = bell.call(0.8, 1.0)
	if u.call() < 0.25:
		var other: int = rng.randi() % ORIGINS
		if other != main:
			a.origins[other] = bell.call(0.1, 0.35)
	var tone: float = 0.0
	var weight: float = 0.0
	for i in ORIGINS:
		tone += a.origins[i] * ORIGIN_TONES[i]
		weight += a.origins[i]
	tone = lerpf(0.2, tone / maxf(weight, 0.001), clampf(weight, 0.0, 1.0))
	a.skin_tone = clampf(tone + bell.call(-0.12, 0.12), 0.0, 1.0)
	a.skin_warmth = bell.call(0.38, 0.62)
	# Eyes: brown wherever the skin is dark; any colour among light-skinned people.
	var eyes: int = maxi((catalogue()["eye_colours"] as Array).size(), 1)
	a.eye_colour = 0 if (main != ORIGIN_WHITE and u.call() < 0.92) or u.call() < a.skin_tone * 2.2 else rng.randi() % eyes
	# Hair: a style for the body, its pigment from the skin's, greying with age.
	a.hair = random_choice(rng, "hair", "female" if female else "male", 0.0 if female else 0.1)
	a.hair_length = bell.call(0.55, 1.0)  # most people wear a style as it is cut; some a little shorter
	a.hair_eumelanin = clampf(a.skin_tone * 1.6 + bell.call(-0.2, 0.7), 0.05, 1.0)
	a.hair_pheomelanin = bell.call(0.6, 1.0) if a.skin_tone < 0.2 and u.call() < 0.08 else bell.call(0.0, 0.3)
	if main != ORIGIN_WHITE:  # dark hair everywhere but among Europeans, where it is any colour
		a.hair_eumelanin = maxf(a.hair_eumelanin, bell.call(0.8, 1.0))
		a.hair_pheomelanin = minf(a.hair_pheomelanin, 0.15)
	if main == ORIGIN_AFRICAN and u.call() < 0.8:  # coiled hair, worn short, as an afro or in curls
		a.hair = random_among(rng, "hair", ["afro", "buzz", "curly", "short_crop"], a.hair)
	elif main == ORIGIN_EAST_ASIAN and u.call() < 0.85:  # straight hair: no curls
		for _try in 6:
			if not ["afro", "curly", "medium_wavy"].has(String(catalogue()["assets"]["hair"][a.hair]["id"])):
				break
			a.hair = random_choice(rng, "hair", "female" if female else "male", 0.0)
	a.hair_grey = clampf((a.years() - 38.0) / 30.0 + bell.call(-0.25, 0.25), 0.0, 1.0)
	a.cut = a.style_cut(a.hair, a.hair_length)
	a.hair_length = 1.0
	var worn: Dictionary = hair_stats()
	var band: int = 0
	if not worn.is_empty():
		while band < worn["age_bands"].size() - 1 and a.years() >= float(worn["age_bands"][band][1]):
			band += 1
		_draw_cut(a, worn["hair"]["female" if female else "male"][band], u, bell, main, seed_value)
	a.eyebrows = rng.randi() % maxi(choice_count("eyebrows"), 1)
	a.eyelashes = rng.randi() % maxi(choice_count("eyelashes"), 1)
	a.beard = 1 + rng.randi() % maxi(choice_count("beard") - 1, 1) if not female and u.call() < 0.4 else 0
	a.beard_length = bell.call(0.0, 0.8)
	a.beard_cut = a.beard_style_cut(a.beard, a.beard_length)
	a.beard_length = 1.0
	if not worn.is_empty() and not female:
		_draw_beard(a, worn["beard"].values()[band], u, bell)
	random_choice(rng, "outfit", "female" if female else "male", 0.0)  # drawn still: every draw after it stays put
	# A face of their own: FLAME's, a real face -- its origin's features (HumanMacros) on top. Then a few body
	# sliders. A normal draw from four uniforms: plain arithmetic, the same on every machine.
	var normal := func() -> float: return (u.call() + u.call() + u.call() + u.call() - 2.0) * 1.7320508
	for k in RANDOM_FLAME_DIRECTIONS:
		var flame_id: int = modifier_id("%s%02d" % [FLAME_PREFIX, k])
		if flame_id != -1:
			a.modifiers[flame_id] = clampf(normal.call() * RANDOM_FLAME_SPREAD / FLAME_RANGE, -1.0, 1.0)
	var sliders: Array = catalogue()["modifiers"]
	var face_tabs: Array = ["head", "eyes", "nose", "mouth", "jaw", "ears", "flame"]
	var body_ids: Array[int] = []
	for id in sliders.size():
		if not String(sliders[id]["key"]) in RANDOM_LEFT_ALONE and not face_tabs.has(sliders[id]["tab"]):
			body_ids.append(id)
	for _body in mini(6 + rng.randi() % 4, body_ids.size()):
		var id: int = body_ids[rng.randi() % body_ids.size()]
		var v: float = bell.call(-0.7, 0.7)
		a.modifiers[id] = absf(v) if sliders[id]["unipolar"] else v
	# The skin: freckles on fair skin, mostly with red or light hair; lines and shadows that come with age.
	var fair: float = clampf(1.0 - a.skin_tone / 0.35, 0.0, 1.0)
	var freckle_chance: float = fair * (0.75 if a.hair_pheomelanin > 0.4 else 0.25)
	a.freckles = bell.call(0.2, 0.9) if u.call() < freckle_chance else 0.0
	a.moles = bell.call(0.0, 0.7)
	a.wrinkles = clampf(wrinkles_at(a.years()) + bell.call(-0.15, 0.15), 0.0, 1.0)
	a.redness = bell.call(0.1, 0.6) * (1.0 - a.skin_tone * 0.6)
	a.eye_bags = clampf(0.15 + 0.4 * clampf((a.years() - 30.0) / 40.0, 0.0, 1.0) + bell.call(-0.1, 0.25), 0.0, 1.0)
	a.unevenness = bell.call(0.1, 0.6)
	# Cheek dimples: about one person in four (drawn last, so the rest of a seeded look stays as it was).
	a.dimples = bell.call(0.4, 1.0) if u.call() < DIMPLE_CHANCE else 0.0
	# Garments from their own numbers: the catalogue's garments grow, and a draw among them must leave the face be.
	a.garments = random_garments(hash([seed_value, "garments"]), "female" if female else "male")
	a.canonicalise()
	return a


## A plausible outfit for [param gender] ("male" / "female"), the same for the same seed: [[position, 0]...].
## Drawn place after place (RANDOM_GARMENT_PLACES), among the garments that suit the gender and go with those
## already drawn (GarmentRules).
static func random_garments(seed_value: int, gender: String) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var entries: Array = garment_entries()
	var worn: Array = []
	var out: Array = []
	for place: Array in RANDOM_GARMENT_PLACES:
		var zone: Dictionary = {"zones": [place[0]]}
		if float(rng.randi() & 0xFFFF) / 65536.0 >= float(place[2]):
			continue
		if place[3] and worn.any(func(w: Dictionary) -> bool: return GarmentRules.overlap(w, zone)):
			continue
		var fits: Array[int] = []
		for i in entries.size():
			var e: Dictionary = entries[i]
			if String(e["id"]) == "none" or not (place[1] as Array).has(int(e.get("layer", 1))):
				continue
			if e.get("gender", "any") != gender and e.get("gender", "any") != "any":
				continue
			if not GarmentRules.overlap(e, zone):
				continue
			if worn.all(func(w: Dictionary) -> bool: return GarmentRules.conflict(w, e) == ""):
				fits.append(i)
		if fits.is_empty():
			continue
		var pick: int = fits[rng.randi() % fits.size()]
		worn.append(entries[pick])
		out.append([pick, 0])
	return out


## [param list] ([[position, tint]...]) made canonical: garments the catalogue has, each once, tints on 0..255,
## each left out when it cannot be worn with one kept before it (GarmentRules), at most MAX_GARMENTS, sorted.
static func canonical_garments(list: Array) -> Array:
	var entries: Array = garment_entries()
	var kept: Array = []
	var seen: Dictionary = {}
	for g: Variant in list:
		if not g is Array or (g as Array).size() < 2:
			continue
		var i: int = int(g[0])
		if i < 0 or i >= entries.size() or seen.has(i) or String(entries[i]["id"]) == "none":
			continue
		var compatible: bool = true
		for k: Array in kept:
			if GarmentRules.conflict(entries[k[0]], entries[i]) != "":
				compatible = false
				break
		if not compatible or kept.size() >= MAX_GARMENTS:
			continue
		seen[i] = true
		kept.append([i, clampi(int(g[1]), 0, 255)])
	kept.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
	return kept


## [param list] made canonical (canonical_garments), then never naked: for each of the COVERED_ZONES it leaves
## bare, the garment covering that zone that goes with what is worn -- of the lowest layer, suiting
## [param gender] ("male" / "female") when one does, the first in the catalogue -- put on.
static func dressed(list: Array, gender: String) -> Array:
	var out: Array = canonical_garments(list)
	var added: bool = false
	for zone: String in COVERED_ZONES:
		if not bare_zones(out).has(zone):  # worn, or covered by what the zone before got (a suit)
			continue
		var pick: int = _cover_for(out, zone, gender)
		if pick < 0:
			pick = _cover_for(out, zone, "")
		if pick >= 0:
			out.push_front([pick, 0])  # first: kept by canonical_garments even with MAX_GARMENTS worn
			added = true
	return canonical_garments(out) if added else out


## The COVERED_ZONES nothing in [param list] ([[position, tint]...]) covers.
static func bare_zones(list: Array) -> Array:
	var entries: Array = garment_entries()
	return COVERED_ZONES.filter(func(zone: String) -> bool:
		return not list.any(func(g: Array) -> bool:
			return int(g[0]) >= 0 and int(g[0]) < entries.size() and covers(entries[g[0]], zone)))


## Whether the garment [param entry] covers the whole GDD zone [param zone] (or the whole body): one side of
## it does not (a holster on the right leg, "8D").
static func covers(entry: Dictionary, zone: String) -> bool:
	return (entry.get("zones", []) as Array).any(func(z: Variant) -> bool: return str(z) == zone or str(z) == "0")


## The garment that covers [param zone] and goes with [param worn], of the lowest layer, suiting [param gender]
## (any garment when ""), the first in the catalogue; -1 when none does.
static func _cover_for(worn: Array, zone: String, gender: String) -> int:
	var entries: Array = garment_entries()
	var best: int = -1
	for i in entries.size():
		var e: Dictionary = entries[i]
		if String(e["id"]) == "none" or not covers(e, zone):
			continue
		if gender != "" and e.get("gender", "any") != gender and e.get("gender", "any") != "any":
			continue
		if not worn.all(func(g: Array) -> bool: return GarmentRules.conflict(entries[g[0]], e) == ""):
			continue
		if best < 0 or int(e.get("layer", 1)) < int(entries[best].get("layer", 1)):
			best = i
	return best


## The catalogue entries of the garments worn, inside out (GarmentRules.stack_order): the order they are drawn in.
func worn_garments() -> Array:
	var entries: Array = garment_entries()
	var out: Array = []
	for g: Array in garments:
		if int(g[0]) < entries.size():
			out.append(entries[g[0]])
	return GarmentRules.stack_order(out)


## Whether a garment worn hides [param what] ("hair", "beard", "face").
func garments_hide(what: String) -> bool:
	for e: Dictionary in worn_garments():
		if (e.get("hides", []) as Array).has(what):
			return true
	return false


## A random look seeded by a text (a player or NPC uuid): the same text, the same person everywhere.
static func from_uuid(uuid: String) -> CharacterAppearance:
	return random(fnv1a(uuid.to_utf8_buffer()))


## A random choice of [param kind] (hair, outfit...) that suits [param gender] ("male" / "female"), or
## "none" (slot 0) with [param none_chance] when the kind has it.
static func random_choice(rng: RandomNumberGenerator, kind: String, gender: String, none_chance: float) -> int:
	var entries: Array = catalogue()["assets"].get(kind, [])
	if entries.is_empty():
		return 0
	if none_chance > 0.0 and float(rng.randi() & 0xFFFF) / 65536.0 < none_chance and entries[0]["id"] == "none":
		return 0
	var fits: Array[int] = []
	for i in entries.size():
		if entries[i]["id"] != "none" and (entries[i]["gender"] == gender or entries[i]["gender"] == "any"):
			fits.append(i)
	return fits[rng.randi() % fits.size()] if not fits.is_empty() else 0


## A head of hair drawn from the families real people of this sex and age wear (hair_stats.json): one
## family by how often it is worn, its settings around its typical cut, its parting and tie as often as
## they come. Coiled hair for most of African origin, straight for most of East Asian origin. Baldness
## and receding hairlines with age, as often as in the photos (men).
static func _draw_cut(a: CharacterAppearance, families: Array, u: Callable, bell: Callable, main: int, seed_value: int) -> void:
	if families.is_empty():
		return
	var pick: float = u.call()
	var family: Dictionary = families[-1]
	for f: Dictionary in families:
		pick -= float(f["weight"])
		if pick <= 0.0:
			family = f
			break
	var fields: Array = hair_stats()["fields"]
	var cut := HairCut.new()
	# Settings added after the first families are drawn from their own numbers: drawn from the look's, they
	# would shift every draw after them -- every NPC's face (from_uuid) would change with the hair statistics.
	var late := RandomNumberGenerator.new()
	late.seed = hash([seed_value, "hair_late_fields"])
	for k in fields.size():
		var spread: float = float(family["spread"][k])
		var roll: float = bell.call(-1.5, 1.5) if k < FIRST_HAIR_FIELDS else (late.randf() + late.randf() + late.randf()) - 1.5
		cut.set(fields[k], clampf(float(family["cut"][k]) + roll * spread, 0.0, 1.0))
	cut.part = _pick_index(family["part"], u.call())
	cut.tie = _pick_index(family["tie"], u.call())
	if main == ORIGIN_AFRICAN and u.call() < 0.8:
		cut.curl = bell.call(0.75, 1.0)
	elif main == ORIGIN_EAST_ASIAN and u.call() < 0.85:
		cut.curl = minf(cut.curl, bell.call(0.0, 0.15))
	# Loose hairs, from the same numbers as the late fields: not in the statistics (photos cannot tell them).
	cut.flyaways = late.randf() * 0.5 if late.randf() < 0.5 else 0.0
	a.cut = cut
	a.hair = maxi(a.hair, 1)


## A beard as often as men of this age wear one (hair_stats.json: full beard, moustache alone, stubble),
## and a bald head or a receding hairline as often.
static func _draw_beard(a: CharacterAppearance, rates: Dictionary, u: Callable, bell: Callable) -> void:
	var roll: float = u.call()
	var styles: Array = catalogue()["assets"].get("beard", [])
	var slot := func(id: String) -> int:
		for i in styles.size():
			if styles[i]["id"] == id:
				return i
		return 0
	a.beard = 0
	if roll < float(rates["beard"]):
		a.beard = slot.call("full")
		a.beard_cut = BeardCut.preset("full")
		a.beard_cut.length = bell.call(0.15, 0.6)
		a.beard_cut.neck = bell.call(0.0, 1.0)
		a.beard_cut.cheeks = bell.call(0.5, 1.0)
	elif roll < float(rates["beard"]) + float(rates["moustache_only"]):
		a.beard = slot.call("moustache")
		a.beard_cut = BeardCut.preset("moustache")
		a.beard_cut.length = bell.call(0.15, 0.4)
	elif roll < float(rates["beard"]) + float(rates["moustache_only"]) + float(rates["stubble"]):
		a.beard = slot.call("stubble")
		a.beard_cut = BeardCut.preset("stubble")
		a.beard_cut.density = bell.call(0.25, 0.7)
	var bald: float = u.call()
	if bald < float(rates["bald"]):
		a.cut.recession = bell.call(0.7, 1.0)
		a.cut.crown_bald = bell.call(0.6, 1.0)
		a.cut.length = minf(a.cut.length, bell.call(0.0, 0.25))
	elif bald < float(rates["bald"]) + float(rates["balding"]):
		a.cut.recession = maxf(a.cut.recession, bell.call(0.3, 0.8))
		a.cut.crown_bald = maxf(a.cut.crown_bald, bell.call(0.0, 0.5))
	if bald < float(rates["bald"]) + float(rates["balding"]):
		a.cut.low_line = 0.0  # a receding line is not a low one


static func _pick_index(weights: Array, roll: float) -> int:
	for i in weights.size():
		roll -= float(weights[i])
		if roll <= 0.0:
			return i
	return weights.size() - 1


## The position of one of [param ids] in a kind's list, drawn at random; [param fallback] if none is there.
static func random_among(rng: RandomNumberGenerator, kind: String, ids: Array, fallback: int) -> int:
	var entries: Array = catalogue()["assets"].get(kind, [])
	var fits: Array[int] = []
	for i in entries.size():
		if ids.has(String(entries[i]["id"])):
			fits.append(i)
	return fits[rng.randi() % fits.size()] if not fits.is_empty() else fallback


# --- presets -------------------------------------------------------------------------------------------

## A named starting look: "default_male", "default_female" (anything else is the man).
static func preset(preset_name: String) -> CharacterAppearance:
	var a := CharacterAppearance.new()
	a.origins[2] = 0.6
	a.skin_tone = 0.15
	a.hair_eumelanin = 0.75
	var female: bool = preset_name == "default_female"
	a.macros["gender"] = 0.0 if female else 1.0
	a.macros["age"] = HumanMacros.age_of(28.0)
	a.macros["height"] = 0.4 if female else 0.55
	a.hair_length = 1.0  # the style as it is cut
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	a.hair = random_choice(rng, "hair", "female" if female else "male", 0.0)
	a.cut = a.style_cut(a.hair)
	for i: int in outfit_garments(random_choice(rng, "outfit", "female" if female else "male", 0.0)):
		a.garments.append([i, 0])
	a.skin_defaults()
	a.canonicalise()
	return a


# --- helpers -------------------------------------------------------------------------------------------

static func _q(v: float) -> float:
	return roundf(clampf(v, 0.0, 1.0) * 255.0) / 255.0


static func _u8(v: float) -> int:
	return int(roundf(clampf(v, 0.0, 1.0) * 255.0))


static func _s8(v: float) -> int:
	return int(roundf(clampf(v, -1.0, 1.0) * 127.0))


static func _slot(value: int, count: int) -> int:
	return clampi(value, 0, maxi(count - 1, 0))
