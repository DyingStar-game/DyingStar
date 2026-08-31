@tool
class_name AtmosphereProfile
extends Resource
## Physical description of one body's atmosphere.
##
## Derived ONCE at import time by addons/dyingstar/build_atmosphere_profiles.gd
## from the system JSON that `services/resourcesDynamic` serves; the client
## never recomputes the scattering integrals. The JSON stays the single source
## of truth for composition, pressure and thickness — never hand-edit the
## derived fields here, regenerate them.
##
## Every field is in SI units and in the body's own frame, so one shader can
## serve every body: an airless moon is the same shader with the betas at zero.

## Samples used when integrating the transmittance on the CPU, with the quadratic spacing described
## in _optical_depth. 64 lands within 0.2 % of a 4096-step reference at every altitude; a uniform
## march needs an order of magnitude more to do the same.
const EXTINCTION_STEPS := 64

@export var planet_radius: float = 0.0          # m
@export var atmosphere_top: float = 0.0         # m above the surface
@export var gravity: float = 0.0                # m/s^2

@export_group("Rayleigh")
## Scattering coefficient at ground level, 1/m, at 680 / 550 / 440 nm.
## Derived from the gas mix: beta = N0 * sum(x_i * sigma_i). These come out ~15%
## below the Nishita constants every tutorial copies, because those assume a flat
## refractive index instead of a dispersion formula.
@export var rayleigh_beta: Vector3 = Vector3.ZERO
@export var rayleigh_scale_height: float = 0.0  # m

@export_group("Mie / haze")
@export var mie_beta: Vector3 = Vector3.ZERO    # 1/m at ground level
@export var mie_g: float = 0.0                  # Henyey-Greenstein asymmetry
## 1.0 = non-absorbing (corundum). Below 1.0 the layer also darkens.
@export var mie_albedo: float = 1.0
## 0 = exponential profile with `mie_scale_height`.
## > 0 = capped, well-mixed layer topped at this altitude.
@export var haze_top: float = 0.0               # m
@export var haze_falloff: float = 0.0           # m, soft upper edge
@export var mie_scale_height: float = 1200.0    # m, only when haze_top == 0

@export_group("Absorption")
## Ozone-like band absorption. Vector3.ZERO when the body has none.
@export var absorption_beta: Vector3 = Vector3.ZERO
@export var absorption_center: float = 25000.0  # m, layer centre
@export var absorption_width: float = 15000.0   # m, half-width

@export_group("Star and ground")
## Albedo of the GROUND, not the planetary (Bond) albedo the system JSON
## publishes: the haze above it is most of what the JSON figure measures.
@export var ground_albedo: float = 0.0
@export var star_irradiance: float = 0.0        # W/m2 at this body
@export var star_angular_diameter: float = 0.0  # degrees
## Effective temperature of the star, K. Drives the colour below.
@export var star_temperature: float = 0.0
## Linear colour of the star, normalised so its brightest channel is 1. Derived
## from star_temperature by a Planck spectrum through the CIE observer, so the
## magnitude stays with star_irradiance and only the hue lives here.
@export var star_color: Color = Color.WHITE


## True when this body has air to scatter light. Airless bodies keep a profile
## (radius and gravity are still useful) but must skip the scattering entirely.
func has_atmosphere() -> bool:
	return atmosphere_top > 0.0 and rayleigh_beta.length_squared() > 0.0


## Fraction of the star's light, per channel, that survives the trip down to
## [param altitude] when the star sits at [param sin_elevation] above the local
## horizon (that is up.dot(to_star), so 1 at the zenith and 0 at the horizon).
## Black when the planet itself is in the way.
##
## This mirrors what atmosphere_common.gdshaderinc integrates for the sky: the
## same profiles, the same coefficients. It cannot literally BE the same code —
## one is GLSL, the other GDScript — so the two are written to look alike, and
## the density functions below carry the same names as their shader twins.
func transmittance_to_star(altitude: float, sin_elevation: float) -> Color:
	if not has_atmosphere():
		return Color.WHITE  # no air to cross
	var top := planet_radius + atmosphere_top
	var sin_e := clampf(sin_elevation, -1.0, 1.0)
	var cos_e := sqrt(maxf(0.0, 1.0 - sin_e * sin_e))
	var origin := Vector3(0.0, planet_radius + altitude, 0.0)
	var dir := Vector3(cos_e, sin_e, 0.0)
	# The planet's own bulk blocks the ray: that IS the terminator, and it needs
	# no softening constant of its own.
	if _ray_sphere(origin, dir, planet_radius).x > 0.0:
		return Color.BLACK
	var exit := _ray_sphere(origin, dir, top).y
	if exit <= 0.0:
		return Color.WHITE
	var depth := _optical_depth(origin, dir, exit, EXTINCTION_STEPS)
	return Color(exp(-depth.x), exp(-depth.y), exp(-depth.z))


## Entry and exit distances of a ray through a sphere of [param radius] centred
## on the origin of this profile's frame, or (-1, -1) when it misses.
func _ray_sphere(origin: Vector3, dir: Vector3, radius: float) -> Vector2:
	var b := origin.dot(dir)
	var c := origin.length_squared() - radius * radius
	var d := b * b - c
	if d < 0.0:
		return Vector2(-1.0, -1.0)
	d = sqrt(d)
	return Vector2(-b - d, -b + d)


## Optical depth along a ray leaving [param origin], with QUADRATIC step spacing: fine near the
## start, coarse far away.
##
## Uniform steps fail badly here, and silently. The column is 110 km tall while Sandbox's haze is a
## 3.5 km slab at the bottom of it, so 24 even steps of 4.6 km either straddle the slab or miss it
## entirely depending on the observer's altitude — measured 126 % error on the vertical transmittance
## at 2000 m, which read 0.90 instead of 0.40. Since the density always falls off away from the
## observer on these rays, spacing the samples by i^2 puts them where the extinction actually is.
func _optical_depth(origin: Vector3, dir: Vector3, distance: float, steps: int) -> Vector3:
	var depth := Vector3.ZERO
	var near := 0.0
	for i in steps:
		var far: float = distance * pow(float(i + 1) / float(steps), 2.0)
		var point: Vector3 = origin + dir * ((near + far) * 0.5)
		# Never below the reference sphere: see atmo_altitude() in the shader. Sandbox's valleys go to
		# -1700 m, and an unclamped depth makes exp(+depth / scale_height) overflow.
		var altitude: float = maxf(0.0, point.length() - planet_radius)
		depth += (
			rayleigh_beta * rayleigh_density(altitude)
			+ mie_beta * mie_density(altitude)
			+ absorption_beta * absorption_density(altitude)
		) * (far - near)
		near = far
	return depth


## Density profiles, normalised to 1 at ground level. Twins of the shader's.

func rayleigh_density(altitude: float) -> float:
	return exp(-altitude / rayleigh_scale_height)


func mie_density(altitude: float) -> float:
	if haze_top > 0.0:
		return 1.0 - smoothstep(haze_top - haze_falloff, haze_top + haze_falloff, altitude)
	return exp(-altitude / mie_scale_height)


func absorption_density(altitude: float) -> float:
	return maxf(0.0, 1.0 - absf(altitude - absorption_center) / absorption_width)
