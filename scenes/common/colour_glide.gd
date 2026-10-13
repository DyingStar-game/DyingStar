class_name ColourGlide
extends RefCounted
## A colour that glides toward its target instead of jumping to it: the dust's colour crossing from
## one biome to the next. The ground's colour comes from one zone at a time, read every half second,
## and the dust switched to the next zone's colour in a single frame (2026-10-11). The first target is
## taken at once: there is nothing to glide from.

## Time constant of the glide (s): about two thirds of the way there after it, all of it after three.
const TIME_S: float = 1.5

var _colour: Color = Color.BLACK
var _laid: bool = false


## The colour after [param delta_s] more seconds gliding toward [param target].
func toward(target: Color, delta_s: float) -> Color:
	if not _laid:
		_colour = target
		_laid = true
		return _colour
	_colour = _colour.lerp(target, 1.0 - exp(-maxf(delta_s, 0.0) / TIME_S))
	return _colour
