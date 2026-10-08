class_name SkySlabs
extends RefCounted
## The dust slab the sky dome is handed (AtmosphereRenderer.weather_storm_slab_*): the storm the eye
## stands in (the dome lights the world, so this is the storm's diffuse light). WeatherSky reads its
## target every REFRESH_S; here it glides to it every frame. Laid at once every half second, a slab's
## height jumped by hundreds of metres under a fast camera and the horizon blinked (2026-10-08).

## The glide rate (1/s) toward each reading.
const GLIDE_RATE: float = 4.0

## The targets of the last reading: the storm slab's extinction (1/m) and its bottom and top (m over
## the planet's reference sphere).
var storm_beta: float = 0.0
var storm_bottom: float = 0.0
var storm_top: float = 0.0

var _laid: bool = false


## A reading's targets are set: the first time, lay them at once on [param renderer] (no glide up
## from 0 m on arrival).
func settle(renderer: AtmosphereRenderer) -> void:
	if _laid:
		return
	_laid = true
	renderer.weather_storm_slab_beta = storm_beta
	renderer.weather_storm_slab_bottom_m = storm_bottom
	renderer.weather_storm_slab_top_m = storm_top


## Every frame: glide [param renderer]'s slab toward the targets.
func glide(renderer: AtmosphereRenderer, delta: float) -> void:
	if not _laid:
		return
	var k: float = 1.0 - exp(-delta * GLIDE_RATE)
	renderer.weather_storm_slab_beta = lerpf(renderer.weather_storm_slab_beta, storm_beta, k)
	renderer.weather_storm_slab_bottom_m = lerpf(renderer.weather_storm_slab_bottom_m, storm_bottom, k)
	renderer.weather_storm_slab_top_m = lerpf(renderer.weather_storm_slab_top_m, storm_top, k)
