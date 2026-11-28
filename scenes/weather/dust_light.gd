class_name DustLight
extends RefCounted
## How the weather's dust is lit, written once for every dust the renderer draws (today the layer near
## the ground, WeatherSky): the sun's beam as it arrives, the beam before the dust over the eye took
## its share, and the light that dust gives back diffuse.
##
## Corundum barely absorbs: what a dust layer takes from the beam comes back scattered. The two-stream
## estimate of the light through a conservative layer of optical depth τ is 1 / (1 + 3/4 (1 - g) τ)
## (60 % at τ 2.6); minus the direct beam exp(-τ / sin e), that is the diffuse part. Lit by the dimmed
## beam alone, a storm's inside read black (2026-10-08). A storm's dust (a dust wall, a dust storm: the
## ground's own dust lifted) is not corundum and absorbs part of what it intercepts (STORM_ALBEDO): the
## same two-stream estimate with absorption ([method total]) lets less through.
##
## The dust over the eye is ALL of it: a storm's (the weather's dust_tau, none with UniformWeather) and
## the planet's own veil (AtmosphereRenderer.veil_tau_above). PlayerSunLight dims the engine's sun by both, so the beam it
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
## dust from below), and a floor for the night. The floor is 0: the terrain's night light is the sky's
## (AMBIENT_SOURCE_SKY), black but for the stars, and a dust glowing at 0.03-0.045 over it drew a grey
## band along the night horizon, brighter than both the sky and the ground (2026-11-25).
const DIRECT_SHARE: float = 0.22
const AMBIENT_FLOOR := Vector3.ZERO
## The storm's dust over the eye (AtmosphereRenderer.storm_tau_above) is read with the weather every half
## second (WeatherSky.REFRESH_S) and glided to over STORM_EASE_S: a wall's front rises over a hundred metres
## (WeatherRelief.WALL_RAMP_M), crossed in 4-12 s, and taken in half-second steps the sun jumped with each read.
const STORM_EASE_S: float = 1.0
## Under this storm optical depth the light is left as it is: the overcast's colour is its own light over the
## share of the sky it replaces, and both tend to nothing together.
const STORM_MIN_TAU: float = 1e-3
## The single-scattering albedo of a storm's dust (a dust wall, a dust storm): the share of the light a
## grain intercepts that it scatters, the rest absorbed (the iron oxides of desert dust). Measured over
## deserts in the visible: 0.90-0.97 (AERONET, Dubovik et al. 2002, J. Atmos. Sci. 59; SHADE, Haywood et
## al. 2003), lower in the blue; 0.9, the dark end, chosen so that a wall reads like a haboob, dusky
## (2026-11-28). With it a wall's 8 optical depths (WeatherRelief.WALL_TAU) leave 6.5 % of the clear light
## on flat ground ([method total]), 36 % without absorption. The dust sea's corundum keeps its own (1).
const STORM_ALBEDO: float = 0.9
## Under this absorption depth (k tau in [method total]) the conservative formula is used: the general
## one divides two vanishing numbers there, and differs from it by less than that.
const CONSERVATIVE_K_TAU: float = 1e-4
## The dust walls near the eye ([method wall_light]): what a wall takes from the light is traced through its
## volume (WeatherRelief.wall_ray), not read in the column over the eye. The sky dome is looked at along
## WALL_SKY_DIRECTIONS lines spread by the cosine of their angle to the zenith (each carries the same share of
## the light falling on level ground). Read over the eye alone, the light changed only once the front was
## overhead and then all at once (a 1 s glide to 8 optical depths), while the sun had long been behind the
## wall, 3 km high in a low evening sun (playtest 2026-11-28).
const WALL_SKY_DIRECTIONS: int = 32
## No wall near: the beam's optical depth (as a vertical one, see wall_light), the share of the sky's light
## let through, the share of the beam given back diffuse, the covered share of the sky.
const NO_WALLS := Vector4(0.0, 1.0, 0.0, 0.0)

## The sky's lines of sight (east, north, up), made once (_sky_directions).
static var _sky: PackedVector3Array = PackedVector3Array()


## The star's beam before any dust, [param star] at [param energy], after the [param air] it crossed
## (the transmittance of the air alone: orange and faint at sunrise, black with the star under the
## horizon).
static func free_beam(star: Color, energy: float, air: Color) -> Vector3:
	return Vector3(star.r * air.r, star.g * air.g, star.b * air.b) * energy


## The light through dust of optical depth [param tau] and single-scattering albedo [param omega] for a
## star [param sin_e] high: [direct, total] (the two-stream total includes the direct beam).
static func split(tau: float, sin_e: float, omega: float = 1.0) -> Vector2:
	var direct: float = exp(-tau / maxf(sin_e, 0.02)) if tau > 0.0 else 1.0
	return Vector2(direct, total(tau, omega))


## The share of the light falling on a dust layer of optical depth [param tau] that comes out under it,
## direct and diffuse together, its grains of single-scattering albedo [param omega] and asymmetry G: the
## two-stream estimate in Eddington's form (Meador & Weaver 1980, J. Atmos. Sci. 37, table 1:
## gamma1 = (7 - omega (4 + 3g)) / 4, gamma2 = -(1 - omega (4 - 3g)) / 4), for light coming in diffuse and
## nothing reflected back from below: T = (1 - r^2) e^(-k tau) / (1 - r^2 e^(-2 k tau)), with
## k = sqrt(gamma1^2 - gamma2^2) and r = gamma2 / (gamma1 + k) the reflectance of a layer too deep to see
## through (the Kubelka-Munk slab). For omega = 1, k = 0 and T = 1 / (1 + 3/4 (1 - g) tau), the
## conservative formula. Taken for the star's light too, whatever its height: that is how the
## conservative case has lit the game since 2026-10-08.
static func total(tau: float, omega: float = 1.0) -> float:
	if tau <= 0.0:
		return 1.0
	var w: float = clampf(omega, 0.0, 1.0)
	var gamma1: float = (7.0 - w * (4.0 + 3.0 * G)) / 4.0
	var gamma2: float = -(1.0 - w * (4.0 - 3.0 * G)) / 4.0
	var k: float = sqrt(maxf(gamma1 * gamma1 - gamma2 * gamma2, 0.0))
	if k * tau < CONSERVATIVE_K_TAU:
		return 1.0 / (1.0 + gamma1 * tau)
	var r: float = gamma2 / (gamma1 + k)
	var fade: float = exp(-k * tau)
	return (1.0 - r * r) * fade / (1.0 - r * r * fade * fade)


## The single-scattering albedo of a column holding [param storm_tau] of storm dust (STORM_ALBEDO) and
## [param clear_tau] of dust that does not absorb (the veil's corundum): each grain's albedo weighed by the
## light it intercepts, its optical depth.
static func column_albedo(storm_tau: float, clear_tau: float) -> float:
	var storm: float = maxf(storm_tau, 0.0)
	var sum: float = storm + maxf(clear_tau, 0.0)
	return (sum - storm * (1.0 - STORM_ALBEDO)) / sum if sum > 0.0 else 1.0


## Hand [param renderer]'s dust shaders the light under [param tau_storm_above] of storm dust over the
## eye (the veil's own column is added here), with [param up] the local vertical: the beam as it
## arrives (dust_sun), the beam before the dust took its share (dust_sun_free), the ambient term and
## the sun's direction.
static func push(renderer: AtmosphereRenderer, up: Vector3, tau_storm_above: float = 0.0) -> void:
	if not is_instance_valid(renderer.sun):
		return
	var profile: AtmosphereProfile = renderer.current_profile()
	var sin_e: float = renderer.sun.star_direction.dot(up)
	var veil: float = renderer.veil_tau_above()
	var light: Vector2 = split(tau_storm_above + veil, sin_e, column_albedo(tau_storm_above, veil))
	# The dust walls near the eye (AtmosphereRenderer.wall_light, wall_light): their direct beam, and their total
	# (that beam plus what they give back diffuse), over the rest of the column's.
	var walls: Vector4 = renderer.wall_light
	var wall_direct: float = exp(-walls.x / maxf(sin_e, 0.02))
	light = Vector2(light.x * wall_direct, light.y * (wall_direct + walls.z))
	# A set sun is HIDDEN, its energy left at its last dusk value: read as is, it lit the dust all night
	# (a white veil over every lamp). The ground has a face that turns away from a sun under the
	# horizon; a grain of dust has none, so the light has to be cut here.
	var c: Color = renderer.sun.light_color * renderer.sun.light_energy \
			if renderer.sun.is_visible_in_tree() else Color.BLACK
	var star: Color = profile.star_color if profile != null else Color.WHITE
	var air: Color = profile.transmittance_to_star(renderer.altitude_above_sphere(), sin_e, 0.0) \
			if profile != null else Color.WHITE
	var free: Vector3 = free_beam(star, renderer.sun.sun_energy, air)
	var ambient_share: float = DIRECT_SHARE * light.x + DIFFUSE_SHARE * maxf(light.y - light.x, 0.0)
	var ambient: Vector3 = free * ambient_share + AMBIENT_FLOOR
	# Under the dust sea the wind's dust is lit like the ground around it: by the sea's overcast, the
	# star's light whitened by the sea (DustSea.light_colour), not by the orange beam of the star through
	# the air, which no longer reaches it (2026-11-26: an orange dust over a grey basin).
	var sea: DustSea = renderer.dust_sea
	var altitude: float = renderer.altitude_above_sphere()
	var share: float = sea.under_share(altitude) if sea.is_on() else 0.0
	if share > 0.0:
		var neutral: Vector3 = free_beam(DustSea.light_colour(star), renderer.sun.sun_energy, air)
		var overcast: Color = sea.overcast(altitude, sin_e, neutral)
		var lit: Array[Vector3] = under_sea(free, ambient, neutral, Vector3(overcast.r, overcast.g, overcast.b), share)
		free = lit[0]
		ambient = lit[1]
	renderer.set_dust_param(&"dust_sun", Vector3(c.r, c.g, c.b))
	renderer.set_dust_param(&"dust_sun_free", free)
	renderer.set_dust_param(&"dust_ambient", ambient)
	renderer.set_dust_param(&"dust_sun_dir", renderer.sun.star_direction)


## The light on the wind's dust with [param share] (0..1) of the dust sea over the eye: the beam before
## the dust goes from [param free] (the star's colour through the air) to [param neutral] (the same
## whitened by the sea), the ambient from [param ambient] to the sea's [param overcast]. [free, ambient].
static func under_sea(free: Vector3, ambient: Vector3, neutral: Vector3, overcast: Vector3,
		share: float) -> Array[Vector3]:
	var s: float = clampf(share, 0.0, 1.0)
	return [free.lerp(neutral, s), ambient.lerp(overcast, s)]


## [param current] (the storm's optical depth over the eye) one frame of [param delta] s closer to
## [param target], easing over STORM_EASE_S.
static func glide_tau(current: float, target: float, delta: float) -> float:
	return target + (current - target) * exp(-maxf(delta, 0.0) / STORM_EASE_S)


## The world's ambient light under [param tau] of storm dust over the eye (a dust wall passing, a storm),
## laid over what lit it before: the engine's ambient is the sky's, but for [param share] of it replaced by
## [param ambient] (the dust sea's overcast; linear, the engine's units). Returns [colour, share] the same way.
##
## What the dust does not absorb (its single-scattering albedo [param omega], STORM_ALBEDO) comes back
## diffuse. The sun's direct beam is dimmed by Beer's law elsewhere (AtmosphereRenderer.transmittance_at);
## here, the light the storm gives back beyond that beam ([param beam], the light reaching its top, at
## [param sin_e]: the two-stream total minus the direct), and everything that already lit the eye diffuse
## (the sky, the sea's overcast) let through as diffuse light is, the two-stream total. On flat ground the
## sum is the total alone: all the light the dust lets through, none invented, the shadows gone. The engine
## mixes its ambient as sky x (1 - share) + colour x share, so the sky's part is dimmed by lowering its share.
static func through_storm(ambient: Vector3, share: float, beam: Vector3, sin_e: float, tau: float,
		omega: float = STORM_ALBEDO) -> Array:
	if tau < STORM_MIN_TAU:
		return [ambient, share]
	var light: Vector2 = split(tau, sin_e, omega)
	return dimmed_ambient(ambient, share, beam * (maxf(sin_e, 0.0) * maxf(light.y - light.x, 0.0)), light.y)


## The world's ambient ([param ambient] for [param share] of it, the engine's sky for the rest, as
## [method through_storm]) when only [param sky_through] of the diffuse light that lit the eye still reaches it
## and the dust gives [param own] back (the sun's light it scattered toward the ground; linear, the engine's
## units). [colour, share] the same way. The engine mixes sky x (1 - share) + colour x share: the sky's part is
## dimmed by lowering its share.
static func dimmed_ambient(ambient: Vector3, share: float, own: Vector3, sky_through: float) -> Array:
	var s: float = clampf(share, 0.0, 1.0)
	var through: float = clampf(sky_through, 0.0, 1.0)
	if through >= 1.0 and own.is_zero_approx():
		return [ambient, share]
	# Floored: with the whole sky let through (a wall in the sun's ray only, between the lines the sky is read
	# along) the dust's own light still has a share to ride; the sky loses a ten-thousandth of its light, unseen.
	var out_share: float = maxf(1.0 - (1.0 - s) * through, 1e-4)
	return [(ambient * (s * through) + own) / out_share, out_share]


## What the dust walls near the eye ([param walls], ClimateWeather.walls_near) leave of the light, traced through
## their volumes (WeatherRelief.wall_ray) from an eye at [param eye] (longitude, latitude, degrees)
## [param eye_height_m] over the ground, the sun along the unit [param sun] (east, north, up) there, on a planet
## of [param radius_m]. Vector4:
## - x: the walls' optical depth along the sun's ray, times the sun's height (its sine, at least 0.02): the
##   vertical depth that dims a star that high by the same (AtmosphereRenderer.transmittance_at); 0 for a set sun.
## - y: the share of the sky's diffuse light that still reaches level ground: the sky dome's lines of sight, each
##   let through as the two-stream total of the slab it crosses ([method total], WeatherRelief.wall_ray's depth
##   across the face it leaves by), the open ones whole.
## - z: the share of the sun's beam (on level ground) the walls give back diffuse: the two-stream total of its
##   ray less its direct part, over the share of the sky the walls cover (what lights the eye from their face).
## - w: the share of the sky the walls cover (cosine-weighted: of the light on level ground), each line of sight
##   as far as it is opaque (1 - e^-tau).
## Inside a wall wide and deep enough that the sky is reached through its top, x, y and z are the column's over
## the eye (through_storm's), and nothing jumps at the front: the walls are traced the same outside and inside.
static func wall_light(walls: Array, eye: Vector2, eye_height_m: float, sun: Vector3, radius_m: float,
		omega: float = STORM_ALBEDO) -> Vector4:
	if walls.is_empty():
		return NO_WALLS
	var sky: PackedVector3Array = _sky_directions()
	var along := PackedFloat64Array()  # by line of sight: the depth across the slabs crossed
	along.resize(sky.size())
	var covered := PackedFloat64Array()  # by line of sight: the optical depth along it
	covered.resize(sky.size())
	var beam := Vector3.ZERO
	var any := false
	for wall: Dictionary in walls:
		var off: Vector2 = WeatherRelief.offset_m(Vector2(float(wall["lon"]), float(wall["lat"])), eye, radius_m)
		var from := Vector3(off.x, off.y, eye_height_m)
		if eye_height_m >= WeatherRelief.wall_tall(wall) + WeatherRelief.WALL_TOP_FADE_M:
			continue  # over its top: every line toward the sky leaves it behind
		if sun.z > 0.0:
			beam += WeatherRelief.wall_ray(wall, from, sun)
		for k in sky.size():
			var ray: Vector3 = WeatherRelief.wall_ray(wall, from, sky[k])
			if ray.z > 0.0:
				along[k] += ray.y
				covered[k] += ray.x
				any = true
	if not any and beam.x <= 0.0:
		return NO_WALLS
	var through := 0.0
	var cover := 0.0
	for k in sky.size():
		through += total(along[k], omega)
		# Covered as far as the line is opaque: what the eye sees along it is the wall's own light for that share,
		# the sky behind for the rest. Smooth across the wall's faces, where its dust thins out.
		cover += 1.0 - exp(-covered[k])
	through /= sky.size()
	cover /= sky.size()
	if sun.z <= 0.0:
		return Vector4(0.0, through, 0.0, cover)
	var direct: float = exp(-beam.x)
	return Vector4(beam.x * maxf(sun.z, 0.02), through, maxf(total(beam.y, omega) - direct, 0.0) * cover, cover)


## The sky's lines of sight, cosine-weighted (a Fibonacci spiral over the unit disc lifted onto the dome: each
## carries the same share of the light on level ground), made once.
static func _sky_directions() -> PackedVector3Array:
	if _sky.is_empty():
		var golden: float = PI * (3.0 - sqrt(5.0))
		for k in WALL_SKY_DIRECTIONS:
			var u: float = (k + 0.5) / WALL_SKY_DIRECTIONS
			var r: float = sqrt(u)
			_sky.append(Vector3(r * cos(k * golden), r * sin(k * golden), sqrt(1.0 - u)))
	return _sky
