@tool
class_name ClimateProfile
extends Resource
## The climate of one body, DERIVED by the weather service's model and written here as data
## (`addons/dyingstar/build_climate_profiles.gd` reads `services/weather/data/derived/<system>.json`):
## the numbers WeatherSampler needs for the wind of each latitude band, the temperature of a place
## and hour, and the air a storm pushes with. Never hand-edit a generated `.tres`: regenerate it.
##
## Why data and not formulas: the service is the single implementation of the derivation
## (`weather-core/src/climate.rs`); the game only composes (band + systems + local), so there is one
## place to be wrong, and this file doubles as the fallback when no weather reaches the client.

## Name of the body in the system data ("SandBox"); informative.
@export var body_name: String = ""
## True when the body has air: no air, no wind, no weather (an airless moon keeps its day).
@export var has_atmosphere: bool = false
## Seed every random-looking decision of the service's weather is drawn from (readouts, tests).
@export var weather_seed: int = 0
## Radius of the reference sphere, metres — distances between a storm and a point run along it.
@export var radius_m: float = 6.356e6
## Surface gravity, m/s² (the same value as PlanetData.surface_gravity, for checks).
@export var surface_gravity: float = 9.8
## Sidereal rotation period, seconds; 0 = no spin.
@export var rotation_period_s: float = 86400.0
## True when the body always shows the same face to its star (fixed day and night sides).
@export var tidal_locked: bool = false
## Axial tilt, degrees (the planet's; > 90 = retrograde).
@export var tilt_deg: float = 0.0
## Orbital period, seconds: the length of a year, which paces the seasons.
@export var orbit_period_s: float = 3.15e7
## Surface pressure, Pa.
@export var pressure_pa: float = 0.0
## Air density at the surface, kg/m³: what a wind pushes with (½ρv²).
@export var rho0_kg_m3: float = 0.0
## Scale height, metres: the air is e times thinner every H.
@export var scale_height_m: float = 8000.0
## Annual-mean irradiance at the top of the air, W/m².
@export var irradiance_w_m2: float = 1361.0
## Bond albedo, the share of light the body sends back.
@export var bond_albedo: float = 0.3
## Equilibrium temperature of the bare body, K.
@export var t_eq_k: float = 255.0
## Mean surface temperature, K.
@export var t_surface_k: float = 288.0
## Half of the day/night temperature range, K.
@export var diurnal_amplitude_k: float = 5.0
## Radiative relaxation time of the air column, seconds (short = cold nights).
@export var radiative_time_s: float = 2.6e6
## Thermal inertia of the ground, J m⁻² K⁻¹ s⁻¹ᐟ² (dust 56, sand 220, rock 2500).
@export var thermal_inertia_tiu: float = 300.0
## Annual-mean equator-to-pole temperature contrast, K.
@export var delta_t_equator_pole_k: float = 35.0
## Coriolis parameter at 45° latitude, s⁻¹ (Earth 1.0e-4): how much the wind is bent.
@export var coriolis_45_s: float = 1.0e-4
## Latitude where the Hadley cell ends, degrees (≥ 90 = one cell pole to pole).
@export var hadley_edge_deg: float = 30.0
## Number of circulation cells per hemisphere: 1 (slow rotator), 2 or 3 (Earth-like).
@export var cells: int = 3
## Surface wind scale, m/s: 40 % of the jet, before the band factor (0.5 trades, 1 westerlies, 0.6 polar).
@export var v10_scale_m_s: float = 10.0
## Gameplay cap on the surface wind, m/s.
@export var wind_scale_max_ms: float = 60.0
## Wind at 10 m that starts lifting the sand, m/s (the dust threshold).
@export var v10_threshold_m_s: float = 7.0
## Speed of sound at the surface, m/s (audio delays and filtering).
@export var sound_speed_m_s: float = 340.0
## Gameplay cap on the dust optical depth of the worst storm.
@export var dust_tau_max: float = 10.0
