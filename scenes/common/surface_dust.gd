class_name SurfaceDust
extends Resource

## Family → how much dust the ground gives up when something rolls or walks on it. The third consumer
## of SurfaceProbe after the footsteps and the tyres: the probe answers WHICH surface, this answers
## HOW DUSTY, and DustEmitter draws the cloud. None of the three knows about the others' job.
##
## The physics is the erodibility of the top layer: loose fine grains (sand, dry dirt) are lifted by
## the smallest shear, bound or hard surfaces (rock, concrete, metal) give almost nothing. The colour
## is the ground's own (GroundLook) unless a family states one — the floor of a building is not the
## colour of the planet under it.
##
## Data, not code: tuning a surface is a number in the Inspector. The vocabulary is the taxonomy's,
## see tools/schema/tags.json.

## family (StringName, e.g. &"sand") → dust given up, 0..1 (0 = none, 1 = the dustiest ground there
## is). Scales both how many particles a step or a wheel throws and how big they are.
@export var amount_by_family: Dictionary = {}

## Dust (0..1) for a family missing from the table, and for an unknown surface. Keep it low: an
## unmapped floor kicking up a sandstorm reads as a bug, a faint puff does not.
@export_range(0.0, 1.0, 0.01) var default_amount: float = 0.2

## family → Color, for surfaces whose dust is NOT the colour of the planet under them (a concrete
## slab, gravel brought in). A family absent from here takes the colour of the ground (GroundLook).
@export var color_by_family: Dictionary = {}

## Colour of the dust when neither the table nor the planet can tell (off-planet, no planet data).
@export var fallback_color: Color = Color(0.55, 0.48, 0.4)

## How much lighter (0..1) the dust is than the ground it comes from: fine grains in the air scatter
## more light than the packed surface. 0 = the exact ground colour, 1 = white.
@export_range(0.0, 1.0, 0.01) var lift_tint: float = 0.25

@export_group("Air")
## How fast (1/s) the air brakes a dust grain. Higher = the cloud stops sooner and hangs where it was
## thrown; 0 = no air at all. Ignored on an airless body, which has none (see DustEmitter).
@export_range(0.0, 10.0, 0.05) var air_drag: float = 2.2
## How fast (m/s²) the dust settles back in air under an Earth gravity (9.81 m/s²), scaled by the body's
## own (DustEmitter): a fine grain is held up by the air's VISCOSITY (Stokes), which barely depends on
## the pressure, so a grain sinks the same in thin air as in thick, at a speed proportional to g. Far
## below the gravity itself on purpose: a fine grain falls at a few centimetres per second. The air's
## density (what slams a door, see DoorWind) does not enter here. Airless, the real gravity applies.
@export_range(0.0, 10.0, 0.05) var air_settle: float = 0.6
## How much (×) a puff swells over its life in air, as it mixes with the air around it. Airless, a
## cloud of grains does not swell — it flies apart on ballistic arcs.
@export_range(1.0, 8.0, 0.1) var air_growth: float = 3.0


## Dust given up by this family, 0..1.
func amount(family: StringName) -> float:
	return clampf(float(amount_by_family.get(family, default_amount)), 0.0, 1.0)


## Colour of this family's dust: its own when the table states one, else the ground's, lightened.
func color(family: StringName, ground: Color) -> Color:
	var base: Color = color_by_family.get(family, ground)
	return base.lerp(Color.WHITE, lift_tint)
