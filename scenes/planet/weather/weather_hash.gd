class_name WeatherHash
extends RefCounted
## The weather service's integer hash (`weather-core/src/hash.rs`), pinned by its golden vectors
## (`test/unit/test_weather_hash.gd`). What the client draws by itself over the service's weather (the
## place of a dust devil, the evening a dust wall falls: WeatherRelief) is drawn from it, so every player
## draws the same.

## SplitMix64's constants, as the signed 64-bit integers GDScript holds (the bits are the same).
const _GOLDEN := -7046029254386353131  # 0x9E3779B97F4A7C15
const _MIX_B := -4417276706812531889   # 0xC2B2AE3D27D4EB4F
const _MIX_C := 1609587929392839161    # 0x165667B19E3779F9
const _STEP_1 := -4658895280553007687  # 0xBF58476D1CE4E5B9
const _STEP_2 := -7723592293110705685  # 0x94D049BB133111EB


## x >> n as on an unsigned 64-bit integer (GDScript's >> keeps the sign).
static func _shr(x: int, n: int) -> int:
	return (x >> n) & ((1 << (64 - n)) - 1)


## One SplitMix64 step.
static func splitmix(x: int) -> int:
	var z := x + _GOLDEN
	z = (z ^ _shr(z, 30)) * _STEP_1
	z = (z ^ _shr(z, 27)) * _STEP_2
	return z ^ _shr(z, 31)


## A seed mixed with three integer coordinates into a 64-bit hash.
static func mix(seed: int, a: int, b: int, c: int) -> int:
	var h := splitmix(seed ^ (a * _GOLDEN))
	h = splitmix(h ^ (b * _MIX_B))
	return splitmix(h ^ (c * _MIX_C))


## A hash as a float in [0, 1): its top 53 bits.
static func unit(h: int) -> float:
	return float(_shr(h, 11)) / 9007199254740992.0
