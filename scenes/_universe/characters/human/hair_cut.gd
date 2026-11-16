class_name HairCut
extends RefCounted

## A head of hair as a few settings -- how long, how curly, which way it is combed, a fringe, tied or not,
## a receding hairline -- from which HairGroom grows it on the head. What an appearance stores and sends:
## BYTES bytes. Any combination is a hair style; the old fixed styles are PRESETS of them.

## Ways the hair is combed: from its natural whorl, parted in the middle, on the left, on the right, swept
## back, standing in a crest along the middle (the rest at the sides' length), or swept up and back off the
## forehead (a quiff: higher with the volume).
enum Part { CROWN, CENTRE, LEFT, RIGHT, BACK, CREST, UP }
## What is done with long hair: worn loose, in a ponytail, in a bun.
enum Tie { LOOSE, PONYTAIL, BUN, TOP_BUN }

const BYTES: int = 12
## Bytes of a cut stored before low_line (appearance version 4), and before flyaways (version 5).
const V4_BYTES: int = 10
const V5_BYTES: int = 11
## Under this length (m, on top) the hair is a stubble: the shell alone, no strands.
const SHELL_ONLY_BELOW: float = 0.012

## 0..1: how long the hair is on top, from shaved (0) to the waist (1); see top_length().
var length: float = 0.3
## 0..1: how long the sides and the back are against the top: 0 = shaved sides (an undercut), 1 = as long.
var sides: float = 0.7
## 0..1: how far the hair stands off the head.
var volume: float = 0.4
## 0..1: straight (0), wavy (~0.35), curly (~0.65), coily (1).
var curl: float = 0.0
## 0..1: how thick the hair is (how many hairs).
var density: float = 0.5
## 0..1: a fringe over the forehead, none (0) to down to the eyes (1).
var fringe: float = 0.0
## 0..1: how far the hairline has receded at the front and the temples.
var recession: float = 0.0
## 0..1: how bald the crown is.
var crown_bald: float = 0.0
## 0..1: how low the front hairline comes down the forehead (a low hairline), from the usual line (0) to
## ~3 cm lower (1). Recession raises it.
var low_line: float = 0.0
## 0..1: loose hairs escaping the cut -- wisps falling by the face and the nape from a tied head of hair, stray hairs
## on a loose one; more along the hairline.
var flyaways: float = 0.0
## Part: which way the hair is combed.
var part: int = Part.CROWN
## Tie: loose, ponytail, bun (low on the crown) or top bun (on top of the head, larger with the volume).
var tie: int = Tie.LOOSE
## A rounder front hairline, lower down the temples (most women's) instead of level across the forehead (most
## men's). Not stored nor sent: the appearance sets it from the body (CharacterAppearance.hair_cut).
var round_line: bool = false

## The fixed styles of the first creator (catalogue ids), as settings: the creator lists them as a start,
## and an appearance that stored one of them (format v3) reads back as it.
const PRESETS: Dictionary = {
	"buzz": {"length": 0.04, "sides": 1.0, "volume": 0.0},
	"short_crop": {"length": 0.2, "sides": 0.45, "volume": 0.3, "curl": 0.05},
	"side_part": {"length": 0.31, "sides": 0.3, "volume": 0.4, "part": Part.LEFT},
	"swept_back": {"length": 0.38, "sides": 0.45, "volume": 0.3, "part": Part.BACK},
	"bob": {"length": 0.62, "sides": 0.75, "volume": 0.5, "part": Part.CENTRE, "fringe": 0.45},
	"medium_wavy": {"length": 0.68, "sides": 0.8, "volume": 0.8, "curl": 0.35, "part": Part.CENTRE},
	"long_straight": {"length": 0.86, "sides": 0.88, "volume": 0.4, "part": Part.CENTRE},
	"ponytail": {"length": 0.75, "sides": 1.0, "volume": 0.2, "tie": Tie.PONYTAIL},
	"bun": {"length": 0.7, "sides": 1.0, "volume": 0.2, "tie": Tie.BUN},
	"curly": {"length": 0.45, "sides": 0.8, "volume": 0.9, "curl": 0.65},
	"afro": {"length": 0.36, "sides": 0.85, "volume": 1.0, "curl": 1.0},
	"crest": {"length": 0.3, "sides": 0.15, "volume": 0.6, "curl": 0.1, "part": Part.CREST},
}


static func preset(id: String) -> HairCut:
	var cut := HairCut.new()
	for key: String in PRESETS.get(id, {}):
		cut.set(key, PRESETS[id][key])
	return cut


## The hair on top (m): shaved to ~0.55 m, finer steps where hair is short.
func top_length() -> float:
	return 0.004 + 0.55 * pow(length, 1.7)


## Sets [member length] so that the hair on top is [param metres] long.
func set_top_length(metres: float) -> void:
	length = clampf(pow(maxf(metres - 0.004, 0.0) / 0.55, 1.0 / 1.7), 0.0, 1.0)


## The sides and back (m).
func side_length() -> float:
	return 0.003 + (top_length() - 0.003) * pow(sides, 1.3)


func shell_only() -> bool:
	return top_length() < SHELL_ONLY_BELOW


func to_bytes() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(BYTES)
	var floats: Array = [length, sides, volume, curl, density, fringe, recession, crown_bald]
	for k in floats.size():
		out[k] = clampi(roundi(float(floats[k]) * 255.0), 0, 255)
	out[8] = clampi(part, 0, Part.size() - 1)
	out[9] = clampi(tie, 0, Tie.size() - 1)
	out[10] = clampi(roundi(low_line * 255.0), 0, 255)
	out[11] = clampi(roundi(flyaways * 255.0), 0, 255)
	return out


static func from_bytes(data: PackedByteArray) -> HairCut:
	var cut := HairCut.new()
	if data.size() < V4_BYTES:
		return cut
	cut.length = data[0] / 255.0
	cut.sides = data[1] / 255.0
	cut.volume = data[2] / 255.0
	cut.curl = data[3] / 255.0
	cut.density = data[4] / 255.0
	cut.fringe = data[5] / 255.0
	cut.recession = data[6] / 255.0
	cut.crown_bald = data[7] / 255.0
	cut.part = clampi(data[8], 0, Part.size() - 1)
	cut.tie = clampi(data[9], 0, Tie.size() - 1)
	cut.low_line = data[10] / 255.0 if data.size() > 10 else 0.0
	cut.flyaways = data[11] / 255.0 if data.size() > 11 else 0.0
	return cut


## The same cut, each setting snapped to [param steps] levels: what NPCs draw on, so that crowds share
## their hair meshes (HairGroom caches one per distinct cut).
func snapped_to(steps: int) -> HairCut:
	var out := HairCut.from_bytes(to_bytes())
	for key in [&"length", &"sides", &"volume", &"curl", &"density", &"fringe", &"recession", &"crown_bald", &"low_line", &"flyaways"]:
		out.set(key, roundf(float(out.get(key)) * (steps - 1)) / (steps - 1))
	return out


## Cache key: the bytes, as text (and the hairline's shape).
func key() -> String:
	return to_bytes().hex_encode() + ("r" if round_line else "")
