class_name DustLight
extends RefCounted
## How the weather's dust is lit, written once for every dust the renderer draws (the near layer, the
## cloud layer, the sky dome's storm slab): the sun's beam as it arrives, the beam before the dust
## over the eye took its share, and the light that dust gives back diffuse.
##
## Corundum barely absorbs: what a dust layer takes from the beam comes back scattered. The two-stream
## estimate of the light through a conservative layer of optical depth τ is 1 / (1 + 3/4 (1 - g) τ)
## (60 % at τ 2.6); minus the direct beam exp(-τ / sin e), that is the diffuse part. Lit by the dimmed
## beam alone, a storm's inside read black (2026-10-08).
##
## The dust over the eye is ALL of it: the storms' (WeatherSky) and the planet's own veil
## (AtmosphereRenderer.veil_tau_above). PlayerSunLight dims the engine's sun by both, so the beam it
## delivers under the cloud sea is 1 % of the star's; computed from that beam, the sea's underside and
## the valleys under it were lit at 1 % too — black at eight in the morning (2026-10-08). The beam
## before the dust is the star's own, at the energy the engine's sun has at the top of the air, after
## the AIR alone (Rayleigh and absorption, no veil, no storm): taken before the air too, the sea was
## lit white at sunrise over an orange ground, and still lit at night (2026-10-09).

## The dust's asymmetry (corundum's forward scattering, the veil's mie_g), and the share of the diffuse
## light the dust's ambient term takes.
const G: float = 0.7
const DIFFUSE_SHARE: float = 0.55
## The share of the direct beam the ambient term takes (the ground around, lit by the sun, lights the
## dust from below), and a floor for the night (the sky's own glow).
const DIRECT_SHARE: float = 0.22
const AMBIENT_FLOOR := Vector3(0.03, 0.035, 0.045)


## The star's beam before any dust, [param star] at [param energy], after the [param air] it crossed
## (the transmittance of the air alone: orange and faint at sunrise, black with the star under the
## horizon).
static func free_beam(star: Color, energy: float, air: Color) -> Vector3:
	return Vector3(star.r * air.r, star.g * air.g, star.b * air.b) * energy


## The light through dust of optical depth [param tau] for a star [param sin_e] high:
## [direct, total] (the two-stream total includes the direct beam).
static func split(tau: float, sin_e: float) -> Vector2:
	var direct: float = exp(-tau / maxf(sin_e, 0.02)) if tau > 0.0 else 1.0
	var total: float = 1.0 / (1.0 + 0.75 * (1.0 - G) * tau)
	return Vector2(direct, total)


## Hand [param renderer]'s dust shaders the light under [param tau_storm_above] of storm dust over the
## eye (the veil's own column is added here), with [param up] the local vertical: the beam as it
## arrives (dust_sun), the beam before the dust took its share (dust_sun_free, for the multiple
## scattering inside a volume), the ambient term and the sun's direction; and the sky slab's multiple
## scattering, its saturated radiance made the diffuse light, T / pi (a Lambertian sky), over the
## dust's albedo.
##
## The cloud layer gets the same three lights BEFORE the air (cloud_sun_beam, cloud_sun_free,
## cloud_ambient, and the night's floor apart): it reads the air over each of its samples itself, so
## that from orbit the sea has its own day and night, not the eye's (2026-10-09).
static func push(renderer: AtmosphereRenderer, up: Vector3, tau_storm_above: float) -> void:
	if not is_instance_valid(renderer.sun):
		return
	var profile: AtmosphereProfile = renderer.current_profile()
	var sin_e: float = renderer.sun.star_direction.dot(up)
	var light: Vector2 = split(tau_storm_above + renderer.veil_tau_above(), sin_e)
	var c: Color = renderer.sun.light_color * renderer.sun.light_energy
	var beam := Vector3(c.r, c.g, c.b)
	var star: Color = profile.star_color if profile != null else Color.WHITE
	var air: Color = profile.transmittance_to_star(renderer.altitude_above_sphere(), sin_e, 0.0) \
			if profile != null else Color.WHITE
	var free: Vector3 = free_beam(star, renderer.sun.sun_energy, air)
	renderer.set_dust_param(&"dust_sun", beam)
	renderer.set_dust_param(&"dust_sun_free", free)
	renderer.weather_storm_slab_ms = light.y / (PI * WeatherSky.BLOW_ALBEDO_MAX)
	var ambient_share: float = DIRECT_SHARE * light.x + DIFFUSE_SHARE * maxf(light.y - light.x, 0.0)
	renderer.set_dust_param(&"dust_ambient", free * ambient_share + AMBIENT_FLOOR)
	var before_air: Vector3 = free_beam(star, renderer.sun.sun_energy, Color.WHITE)
	renderer.set_dust_param(&"cloud_sun_beam", before_air * light.x)
	renderer.set_dust_param(&"cloud_sun_free", before_air)
	renderer.set_dust_param(&"cloud_ambient", before_air * ambient_share)
	renderer.set_dust_param(&"cloud_ambient_floor", AMBIENT_FLOOR)
	renderer.set_dust_param(&"dust_sun_dir", renderer.sun.star_direction)
