class_name BeardCut
extends RefCounted

## A beard as a few settings -- where it grows, how long, how thick, its shape -- from which BeardGroom
## grows it on the face. What an appearance stores and sends: BYTES bytes. The old fixed beards are PRESETS.

## Shapes of a long beard's bottom.
enum Shape { ROUNDED, SQUARE, POINTED }

const BYTES: int = 8
## Zones of the face a beard covers, in HairHead.beard_zones order.
const ZONES: Array[StringName] = [&"moustache", &"chin", &"cheeks", &"neck"]
## Under this hair length (m) a beard is a stubble: the shell alone.
const SHELL_ONLY_BELOW: float = 0.004

## 0..1: how much of each zone it covers.
var moustache: float = 1.0
var chin: float = 1.0
var cheeks: float = 1.0
var neck: float = 0.6
## 0..1: stubble (0) to a long beard (1); see hair_length().
var length: float = 0.3
## 0..1: how thick it is (how many hairs).
var density: float = 0.6
## 0..1: how much the moustache joins the chin down the sides of the mouth.
var connect: float = 1.0
## Shape: the bottom of a long beard.
var shape: int = Shape.ROUNDED

const PRESETS: Dictionary = {
	"full": {"length": 0.33},
	"moustache": {"chin": 0.0, "cheeks": 0.0, "neck": 0.0, "connect": 0.0, "length": 0.27},
	"goatee": {"cheeks": 0.0, "neck": 0.0, "length": 0.31},
	"stubble": {"length": 0.02, "density": 0.45},
}


static func preset(id: String) -> BeardCut:
	var cut := BeardCut.new()
	for key: String in PRESETS.get(id, {}):
		cut.set(key, PRESETS[id][key])
	return cut


## The beard's hair (m): 1.5 mm of stubble to ~12 cm.
func hair_length() -> float:
	return 0.0015 + 0.12 * pow(length, 1.6)


func shell_only() -> bool:
	return hair_length() < SHELL_ONLY_BELOW


## How much of zone [param z] (ZONES order) it covers.
func coverage(z: int) -> float:
	return [moustache, chin, cheeks, neck][z]


func to_bytes() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(BYTES)
	var floats: Array = [moustache, chin, cheeks, neck, length, density, connect]
	for k in floats.size():
		out[k] = clampi(roundi(float(floats[k]) * 255.0), 0, 255)
	out[7] = clampi(shape, 0, Shape.size() - 1)
	return out


static func from_bytes(data: PackedByteArray) -> BeardCut:
	var cut := BeardCut.new()
	if data.size() < BYTES:
		return cut
	cut.moustache = data[0] / 255.0
	cut.chin = data[1] / 255.0
	cut.cheeks = data[2] / 255.0
	cut.neck = data[3] / 255.0
	cut.length = data[4] / 255.0
	cut.density = data[5] / 255.0
	cut.connect = data[6] / 255.0
	cut.shape = clampi(data[7], 0, Shape.size() - 1)
	return cut


func key() -> String:
	return to_bytes().hex_encode()
