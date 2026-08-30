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
