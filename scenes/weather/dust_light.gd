class_name DustLight
extends RefCounted
## How the weather's dust is lit, written once for every dust the renderer draws (the near layer, the
## storm volume, the sky dome's storm slab): the sun's beam as it arrives, dimmed by the dust over the
## eye, and the light that dust gives back diffuse.
##
## Corundum barely absorbs: what a dust layer takes from the beam comes back scattered. The two-stream
## estimate of the light through a conservative layer of optical depth τ is 1 / (1 + 3/4 (1 - g) τ)
## (60 % at τ 2.6); minus the direct beam exp(-τ / sin e), that is the diffuse part. Lit by the dimmed
## beam alone, a storm's inside read black (2026-10-08).

## The dust's asymmetry (corundum's forward scattering, the veil's mie_g), and the share of the diffuse
## light the dust's ambient term takes.
const G: float = 0.7
const DIFFUSE_SHARE: float = 0.55


## The light through dust of optical depth [param tau] for a star [param sin_e] high:
## [direct, total] (the two-stream total includes the direct beam).
static func split(tau: float, sin_e: float) -> Vector2:
	var direct: float = exp(-tau / maxf(sin_e, 0.02)) if tau > 0.0 else 1.0
	var total: float = 1.0 / (1.0 + 0.75 * (1.0 - G) * tau)
	return Vector2(direct, total)


## Hand [param renderer]'s dust shaders the light under [param tau_above] of dust over the eye, with
## [param up] the local vertical: the beam (dust_sun), the beam before the dust took its share
## (dust_sun_free, for the volume's multiple scattering), the ambient term and the sun's direction; and
## the sky slab's multiple scattering, its saturated radiance made the diffuse light, T / pi (a
## Lambertian sky), over the dust's albedo.
static func push(renderer: AtmosphereRenderer, up: Vector3, tau_above: float) -> void:
	if not is_instance_valid(renderer.sun):
		return
	var c: Color = renderer.sun.light_color * renderer.sun.light_energy
	var light: Vector2 = split(tau_above, renderer.sun.star_direction.dot(up))
	var direct: float = light.x
	var diffuse: float = maxf(light.y - direct, 0.0)
	var beam := Vector3(c.r, c.g, c.b)
	var unstormed: Vector3 = beam / maxf(direct, 1e-3)  # the beam before the dust took its share
	renderer.set_dust_param(&"dust_sun", beam)
	renderer.set_dust_param(&"dust_sun_free", unstormed)
	renderer.weather_storm_slab_ms = light.y / (PI * WeatherSky.BLOW_ALBEDO_MAX)
	renderer.set_dust_param(&"dust_ambient", unstormed * (0.22 * direct + DIFFUSE_SHARE * diffuse)
			+ Vector3(0.03, 0.035, 0.045))
	renderer.set_dust_param(&"dust_sun_dir", renderer.sun.star_direction)
