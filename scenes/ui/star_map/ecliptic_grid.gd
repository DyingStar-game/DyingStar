class_name EclipticGrid
extends MeshInstance3D

## The plane the system's orbits lie in, marked by the CROSSINGS of a grid, under everything else.
##
## A chart of inclined orbits without one is a tangle: nineteen curves crossing at every angle, and no
## way to tell whether a body is above the plane or below it. The plane is the floor that answers that,
## and the stalks the chart drops from each body to it turn the answer into a distance.
##
## Dots rather than lines — see the shader. A lattice of crossings says the same thing as a mesh for a
## fraction of the pixels, and the eye joins them up by itself.

## Print what the plane is being given, to the client log, whenever it CHANGES.
##
## The plane has now vanished twice for reasons I guessed at and got wrong, so it gets an instrument
## instead of another theory. Four numbers tell every story it can tell: where the plane is relative to
## the camera, how big the quad is, how coarse the lattice is, and where the fade bites. Set to false
## before the branch is committed.
const DEBUG_PLANE: bool = false

## How much of the reference distance the fine lattice aims to put between two crossings, before
## rounding to a round number.
##
## A tenth was reasoned from the HEIGHT of the view and is far too fine in practice: the plane is seen
## at a grazing angle, so it recedes well past the distance it was sized on and a dozen cells across
## the near field becomes several hundred crossings filling the frame. At that count the lattice stops
## reading as a floor and becomes a texture you have to look THROUGH. A quarter is the same measure
## taken against the whole depth of the view rather than its height.
const CELL_TARGET: float = 0.25
## How far the quad reaches, in those same distances. Generous: it is two triangles, and a plane that
## stops before the horizon looks like a rug rather than a plane.
const EXTENT: float = 60.0
## Where it begins to fade and where it is gone.
##
## Wide and gentle, which is the opposite of what it was. A tight band draws a HARD EDGE across the
## picture: on a plane seen at a grazing angle, the points at a given distance from the camera form a
## conic that projects to a near-horizontal line, and the whole transition is crushed into a few pixels
## of it. The fade was doing its job and it looked like the plane had been cut off with scissors.
##
## The far field no longer needs it in any case. What actually retires the distance is the lattice
## becoming finer than the pixels drawing it — and THAT has no locus: it arrives gradually, from every
## direction at once, exactly as a horizon should.
const FADE_START: float = 3.0
const FADE_END: float = 12.0
## Floor on that distance, as a fraction of the view: sitting exactly in the plane there is no scale to
## derive, and every number below would be a division by zero.
const NEAREST: float = 0.01

const GRID_SHADER := preload("res://assets/shaders/ecliptic_grid.gdshader")

var _material: ShaderMaterial = null


func _ready() -> void:
	var quad := PlaneMesh.new()
	quad.size = Vector2.ONE
	# Its own orientation is already the orbital plane: PlaneMesh lies in XZ with its normal up, and XZ
	# is where kepler_orbit.gd puts the orbits.
	mesh = quad
	_material = ShaderMaterial.new()
	_material.shader = GRID_SHADER
	material_override = _material
	# Under everything: the grid is a background against which the rest is read, never a thing in its
	# own right. Orbit rings and bodies must win wherever they overlap it.
	_material.render_priority = -1


## Place and scale the grid for this frame.
##
## [param plane_y] is where the orbital plane sits in DRAWN coordinates — the chart is offset so that
## what the camera watches is at the origin, so the plane is almost never at zero.
func refresh(view: float, shift: Vector3, camera_at: Vector3, plane_y: float) -> void:
	if view <= 0.0:
		visible = false
		return
	visible = true
	# The LARGER of two distances, and it needs both.
	#
	# How far the camera stands from the plane, because that is the scale the plane is seen at: down
	# among the towns of a planet the view distance is a few km while the system's plane is two million
	# away, and a lattice sized on the view was finer than a pixel there, with a quad too small to even
	# reach it. The plane vanished whenever you came close to anything.
	#
	# And the view distance, because the first one moves when you PITCH. Orbiting swings the camera up
	# and down relative to the plane, so a spacing derived from its height alone changed as you looked
	# around — and since the spacing is rounded to a 1, 2 or 5, it did not drift, it JUMPED by a factor
	# of two. The view distance does not move when you orbit, so taking the larger of the two holds the
	# lattice still under the one gesture that must not disturb it.
	var away: float = maxf(maxf(absf(camera_at.y - plane_y), view), view * NEAREST)
	# Centred under the camera rather than on the system: the quad only has to cover what is on screen.
	position = Vector3(camera_at.x, plane_y, camera_at.z)
	scale = Vector3(away * EXTENT, 1.0, away * EXTENT)
	_material.set_shader_parameter("grid_step", StarMapScale.nice_length(away * CELL_TARGET))
	# The offset the whole scene is drawn with, given back, so the lattice stays nailed to the system
	# instead of sliding under it as the origin follows the subject.
	_material.set_shader_parameter("origin_offset", Vector2(shift.x, shift.z))
	_material.set_shader_parameter("fade_start", away * FADE_START)
	_material.set_shader_parameter("fade_end", away * FADE_END)
	_material.set_shader_parameter("intensity", 1.0)
	_watch(view, camera_at, plane_y, away)


## The last line printed, so a situation that has not changed says nothing.
var _said: String = ""


## One line per CHANGE of situation, in units of a thousand km so the numbers can be read.
##
## [code]sous[/code] is how far the camera stands above the plane — the whole geometry in one number:
## if it dwarfs the quad's reach the plane is simply below the frame, and no amount of fading is
## involved. [code]porte[/code] is that reach, [code]pas[/code] the spacing between crossings, and
## [code]voile[/code] where the far fade begins and ends. A plane that is drawn but invisible, one that
## is off screen, and one that is faded out are three different failures and these tell them apart.
func _watch(view: float, camera_at: Vector3, plane_y: float, away: float) -> void:
	if not DEBUG_PLANE:
		return
	var km: float = 1.0e3  # a chart unit is a million km, so this reads in thousands of km
	var state: String = ("vue=%.0f sous=%.0f porte=%.0f pas=%.0f voile=%.0f..%.0f visible=%s"
			% [view * km, (camera_at.y - plane_y) * km, away * EXTENT * km,
			StarMapScale.nice_length(away * CELL_TARGET) * km,
			away * FADE_START * km, away * FADE_END * km, str(visible)])
	if state == _said:
		return
	_said = state
	print("[Plan] %s" % state)
