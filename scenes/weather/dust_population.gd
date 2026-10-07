class_name DustPopulation
extends Resource
## One population of the weather's dust (WeatherDust: the clouds past the visor, the low veils, the
## saltation streaks, the wisps): how many a second at full strength, how big, how faint, how they
## stream, where around the camera they are born and how they move. Tuned in the weather effects scene
## (res://scenes/weather/weather_effects.tscn) and read live by StormDust, so a change in the Inspector
## — the remote one while the game runs — shows within half a second.

## Puffs per second when the population is at full strength (a full storm for the clouds, twice the
## ground's lift threshold for the others).
@export_range(0.0, 400.0, 0.5) var rate_full: float = 10.0
## Size of a puff at birth (m).
@export_range(0.01, 30.0, 0.01) var size_m: float = 1.0
## How dense a puff is drawn (0..1), on top of the ground's own dustiness.
@export_range(0.0, 1.0, 0.01) var opacity: float = 1.0
## How much longer a grain is drawn along its motion, per m/s of speed (0 = round puffs).
@export_range(0.0, 0.5, 0.005) var stretch_per_ms: float = 0.0
## How long a puff lives (s). Changing it lays a fresh emitter.
@export_range(0.1, 20.0, 0.05) var lifetime_s: float = 2.0
## Puffs alive at once at most. Changing it lays a fresh emitter.
@export_range(8, 2048, 1) var capacity: int = 256
## Born this far upwind of the camera (m), along the ground.
@export_range(0.0, 100.0, 0.5) var upwind_m: float = 10.0
## Spread of the births across the wind (m); half of it along the wind.
@export_range(0.0, 100.0, 0.5) var spread_m: float = 8.0
## For the clouds: spread up and down around the eye (m). For the others: height over the ground (m).
@export_range(0.0, 20.0, 0.05) var height_m: float = 1.0
## Share of the wind's speed a puff leaves with (0..1.5).
@export_range(0.0, 1.5, 0.01) var speed_share: float = 1.0
## Upward speed at birth (m/s): the hop of a streak, the rise of a wisp.
@export_range(0.0, 10.0, 0.05) var rise_ms: float = 0.0
## Grains per puff, and the radius of the patch they come from (m).
@export_range(1, 8, 1) var grains: int = 1
## Radius of the patch a puff's grains come from (m).
@export_range(0.0, 5.0, 0.05) var patch_m: float = 0.5


## A population from its numbers, in the order of the exports (the code's defaults, WeatherDust).
static func make(rate: float, size: float, alpha: float, stretch: float, life: float, cap: int, upwind: float,
		spread: float, height: float, share: float, rise: float, count: int, patch: float) -> DustPopulation:
	var p := DustPopulation.new()
	p.rate_full = rate
	p.size_m = size
	p.opacity = alpha
	p.stretch_per_ms = stretch
	p.lifetime_s = life
	p.capacity = cap
	p.upwind_m = upwind
	p.spread_m = spread
	p.height_m = height
	p.speed_share = share
	p.rise_ms = rise
	p.grains = count
	p.patch_m = patch
	return p
