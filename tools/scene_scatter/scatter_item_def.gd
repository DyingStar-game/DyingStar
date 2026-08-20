@tool
class_name ScatterItemDef
extends Resource
## One scene entry in a [SceneScatter] mix: the scene to instance, how often it is picked,
## and how each instance is randomly varied.
##
## Mirrors the shape of [VegetationRule] (same "Transform" group, same scale/yaw/tilt knobs)
## so the two scattering systems read the same way in the inspector.


## The scene instanced for each placement using this entry.
@export var scene: PackedScene

## Relative share of this entry in the mix. Any positive ratio works — the weights of all
## entries are summed and normalised, exactly like MiningZone's weight_small/medium/large.
## A weight of 0 disables the entry without removing it from the list.
@export var weight: float = 1.0


@export_group("Transform")
## Each instance picks a uniform scale in [member scale_min]..[member scale_max].
@export var scale_min: float = 1.0
@export var scale_max: float = 1.0
## Whether to apply a random rotation around the placement's up axis.
@export var random_yaw: bool = true
## Maximum random tilt (degrees) applied on top of the ground alignment, to break up
## the "everything perfectly upright" look.
@export_range(0.0, 90.0, 0.1) var max_tilt_deg: float = 0.0
## Offset along the surface normal — negative sinks the instance into the ground, positive
## lifts it. Use it when a scene's origin is not at its base.
@export var surface_offset: float = 0.0


## Default entry for [param scene], used by [method SceneScatter.resolve_items] to turn the
## node's plain "scenes" list into a mix — so dropping a .tscn straight into the inspector
## behaves exactly like an [ScatterItemDef] left at its defaults.
static func for_scene(scene: PackedScene) -> ScatterItemDef:
	var item := ScatterItemDef.new()
	item.scene = scene
	return item


## Uniform scale for one instance, drawn from [member scale_min]..[member scale_max].
## Tolerates a reversed range (min > max) rather than returning garbage.
func pick_scale(rng: RandomNumberGenerator) -> float:
	var lo: float = minf(scale_min, scale_max)
	var hi: float = maxf(scale_min, scale_max)
	if is_equal_approx(lo, hi):
		return lo
	return rng.randf_range(lo, hi)


## True when this entry can actually produce an instance (a scene is set and the weight
## gives it a chance of being picked).
func is_usable() -> bool:
	return scene != null and weight > 0.0
