class_name StarMapCamera
extends RefCounted

## Where the chart's camera sits, what it follows, and how close it is allowed to get.
##
## Deliberately free of nodes: it holds numbers and the rules that govern them, so those rules can be
## exercised without a viewport, a world or a player. [StarMap] owns the actual [Camera3D] and asks this
## object where to put it.
##
## It does not know what a body is, either. Everything it needs about one — the radius to frame it from,
## the radius to stay clear of — is handed in by the chart, which is the only thing holding the list.

## Vertical field of view of the chart's camera, in degrees, and what it means in world units: the
## screen covers 2·tan(fov/2) of the distance to the subject.
##
## Stated here and APPLIED to the camera rather than left to Godot's default, because four separate
## derivations lean on it — how far a body is framed from, when a body is big enough to carry its
## towns, how big a badge is drawn, and what the scale bar says. Left implicit, changing the camera's
## fov would quietly falsify all four.
const FOV_DEGREES: float = 75.0
const SCREEN_SPAN: float = 1.5344

## Camera distance limits, in units (1e6 km): from close over a moon out past Tarsis 8.
##
## ZOOM_MIN is now only a backstop against a degenerate near plane; what actually stops the camera is
## SURFACE_CLEARANCE, which knows what it is approaching. It had to come down for that to be true: at
## 0.01 units — ten thousand km — it sat ABOVE the clearance of a 6 356 km planet, so it, and not the
## surface, decided how close you could get. A small moon could then never fill more than a seventh of
## the screen however hard you zoomed.
const ZOOM_MIN: float = 1.0e-6
const ZOOM_MAX: float = 8000.0
const ZOOM_STEP: float = 1.15
## How fast the +/- keys zoom, as a factor per second held.
const KEY_ZOOM_RATE: float = 6.0
const ORBIT_SENSITIVITY: float = 0.005
## Floor on how far the sensitivity may fall as you close in.
##
## Not there to keep the gesture usable — it cannot become unusable. The ground swept by one pixel is
## [constant ORBIT_SENSITIVITY] times the height above the surface, while the screen at that height
## shows about 1.53 times it, so one pixel moves a THIRD OF A PERCENT of the screen whatever the
## altitude. The rate is already scale-free; a floor can only make it too fast.
##
## Which is what it did. At two thousandths the floor bound below 12.7 km up — 0.002 of a 6 356 km
## radius — and the chart now goes far closer than that: at 4 km it turned 3.2 times too fast for the
## view, at 1 km nearly thirteen times. This is a guard against the degenerate case only, where the
## camera sits exactly on its clearance and the gesture would otherwise freeze. The closest approach
## allowed is [constant SURFACE_CLEARANCE_M], a hundred metres, which is 1.6e-5 of that radius — so in
## honest use this never binds at all.
const ORBIT_MIN_SCALE: float = 1.0e-5
## Pitch is clamped short of the poles: straight down the axis, the rings collapse to lines.
const PITCH_LIMIT: float = 1.45
## How far a selected body is framed from, in multiples of its own radius.
##
## Derived, not chosen by eye. The chart's camera has Godot's default 75° vertical field, so the screen
## covers 2·tan(37.5°) ≈ 1.53 of the distance to the subject; a body of radius r at distance d therefore
## spans 2r / (1.53·d) of the screen height. At 1.8 radii that is 73 % — the body fills the view and you
## can read its surface. The old value of 40 radii put it at 3 %: a click "framed" a planet by leaving it
## a speck, which read as the click having done nothing at all.
const FOCUS_ZOOM: float = 1.8

## One metre, in chart units — the chart counts in millions of km.
const METRE: float = 1.0e-9

## Closest the camera may come to the GROUND beneath it, in METRES.
##
## This is the floor that was missing, and its absence is what let a click bury the camera inside the
## star. ZOOM_MIN is 0.01 units — ten thousand km — while the star alone is 0.571 units in radius, so
## any path reaching the floor ended up inside it: a black screen with no way out but Reset. A floor
## written as an absolute DISTANCE FROM THE CENTRE cannot serve a chart whose subjects span six orders
## of magnitude. What it has to measure is the gap to the ground — and that is the same question at
## every scale, which is why this is a gap and no longer a ratio.
##
## 1.0002 radii read well enough: 1.3 km over Tarsis III, 700 m over Tarsis VIII. But it made every
## altitude the chart can express a function of which body you happen to be over, so asking for a
## definite one — as framing yourself does — was asking for something the floor might quietly refuse.
## A hundred metres is a hundred metres anywhere.
##
## Kept far below any framing a click gives, so there is always room left to lean in with the wheel. It
## is only reachable because the near plane follows the GAP to the surface rather than the distance to
## the body's centre; at three hundred km, where this used to stop, the two are indistinguishable, and
## past that the old near plane would have clipped away the very surface you were descending towards.
const SURFACE_CLEARANCE_M: float = 100.0

## The view the chart opens on, and the one Reset returns to. Constants rather than literals, so the
## button and the initial state cannot drift apart.
##
## 140 units frames the inner system: SandBox's orbit spans the view, its neighbours are placed around
## it and the outer giants sit just past the edge, where they can be reached by a search or a scroll.
## It opened at 1200 — the whole system seen from eight times its own width — which is honest and
## unhelpful: every body a couple of pixels wide, and nothing to read.
const DEFAULT_ZOOM: float = 140.0
const DEFAULT_YAW: float = 0.0
const DEFAULT_PITCH: float = 0.55

## How long the camera takes to travel to a new subject.
##
## Long enough to read as movement rather than a cut: the chart spans five orders of magnitude, and a
## cut between two of them tells you nothing about how far you just went or where you came from. Short
## enough that it is never a wait.
const TRANSITION_S: float = 0.45

## Distance the camera is heading for. What it is drawn at right now is [method distance], which differs
## while a travel is in flight.
var zoom: float = DEFAULT_ZOOM
var yaw: float = DEFAULT_YAW
var pitch: float = DEFAULT_PITCH
## What is SELECTED: the info panel describes it and the halo rings it. Independent of what the camera
## watches, and that separation is the whole input model — a click tells you about a thing, a double
## click takes you to it. Merging the two meant you could not read about a moon without losing the view
## you were reading it from.
var focus: int = -1
## The selected body's KEY. Kept so that closing and reopening the chart — which rebuilds the list —
## puts you back on the same body even though every index may have shifted.
var focus_key: String = ""

## Body the camera keeps watching when nothing is SELECTED, and the point to fall back on when that
## index no longer exists. Entry zero is the star, which is where the chart opens.
##
## A deselect must not move the camera. Clicking empty space is how you drop a selection, and throwing
## the view back across the system every time would be worse than the bug it replaced — Reset is the
## button for going home, and it is one click away. The camera therefore keeps watching what it was
## watching; only the selection goes.
var anchor_body: int = 0
var anchor: Vector3 = Vector3.ZERO

var _from_point: Vector3 = Vector3.ZERO
var _from_zoom: float = DEFAULT_ZOOM
var _from_yaw: float = DEFAULT_YAW
var _from_pitch: float = DEFAULT_PITCH
var _point_blend: float = 1.0
var _zoom_blend: float = 1.0
var _angle_blend: float = 1.0


## The one place a distance is ever decided. A single clamp at the single point of truth is what makes
## "the camera is never inside a body" hold by construction, rather than holding in whichever paths
## somebody remembered to guard.
func clamp_zoom(z: float, guard_radius: float) -> float:
	return clampf(z, maxf(ZOOM_MIN, guard_radius + SURFACE_CLEARANCE_M * METRE), ZOOM_MAX)


## Keep the camera above the ground while the GROUND moves under it.
##
## [method clamp_zoom] runs wherever a distance is written, and that was taken for enough. It is not:
## orbiting writes no distance, so turning from a plain onto a mountain raises the ground through a
## camera that never moved. Nor does it catch a caller that hands over a guard of zero — which is what
## framing a thing with no radius does, and how "go to me" from the search box buried the camera inside
## the planet under the player's feet.
##
## Applied every frame, from what the chart currently measures under the camera, this is the floor that
## cannot be bypassed by forgetting to ask. The per-write clamp stays: it is what makes a zoom converge
## smoothly onto the surface rather than be dragged back to it a frame later.
func hold_above(guard_radius: float) -> void:
	zoom = clamp_zoom(zoom, guard_radius)


## A deliberate zoom — wheel or key. It settles the travel immediately: an input the user is holding has
## to answer under their hand, not queue behind an animation.
func set_zoom(z: float, guard_radius: float) -> void:
	zoom = clamp_zoom(z, guard_radius)
	_zoom_blend = 1.0


## One notch of the wheel, or one moment of the zoom key.
##
## Multiplies the HEIGHT above the surface, never the distance to the centre. Those are the same number
## out in space and nothing alike near a planet: a fifteen per cent step on a distance of 6 356 km is
## 950 km, so from a hundred km up a single notch either pinned you to the floor or threw you out of
## sight. On the height, fifteen per cent means fifteen per cent of what you can see, at every scale —
## and far away, where the radius is negligible beside the distance, it is the old behaviour exactly.
##
## Taken from the CURRENT drawn distance rather than the goal, so scrolling during a travel takes over
## from where the view visibly is instead of snapping to where it was going.
func scale_zoom(factor: float, guard_radius: float) -> void:
	var height: float = maxf(distance() - guard_radius, 0.0)
	set_zoom(guard_radius + height * factor, guard_radius)


## Turn around the subject. Takes over from where the view visibly IS, and settles any turn in flight:
## a hand on the mouse outranks an animation.
##
## [param guard_radius] is the radius of what is being orbited, and it is what makes the gesture
## usable up close — see [method _orbit_scale].
func orbit(relative: Vector2, guard_radius: float) -> void:
	var rate: float = ORBIT_SENSITIVITY * _orbit_scale(guard_radius)
	var from_yaw: float = facing_yaw()
	var from_pitch: float = facing_pitch()
	_angle_blend = 1.0
	yaw = from_yaw - relative.x * rate
	pitch = clampf(from_pitch + relative.y * rate, -PITCH_LIMIT, PITCH_LIMIT)


## How much of the full sensitivity applies at the current distance.
##
## Orbiting turns the camera AROUND the subject, so the piece of surface under it slides by radius·dθ —
## while the patch of that surface actually on screen is only about 1.53·(distance − radius) across. The
## ratio between the two blows up on approach: three hundred km over a 6 356 km planet, a turn that
## moves the view by a fifth of a screen out in space sweeps six screens' worth of ground. Precision is
## exactly what you want when you are close, so the rate follows the gap to the surface.
func _orbit_scale(guard_radius: float) -> float:
	if guard_radius <= 0.0:
		return 1.0
	return clampf((distance() - guard_radius) / guard_radius, ORBIT_MIN_SCALE, 1.0)


## Select without moving a thing. A click answers "what is that?", and answering a question is no
## reason to throw away the view the question was asked from.
func select(index: int, key: String) -> void:
	focus = index
	focus_key = key


func deselect() -> void:
	focus = -1
	focus_key = ""


## Travel to [param index] and frame it — what a double click does.
##
## [param guard_radius] is separate from [param frame_radius] because the two differ for the player
## marker: it has no radius of its own, but it sits ON a surface, so the thing to stay clear of is the
## body underneath it. [param framing] overrides how many radii out to stop, for the cases where the
## ordinary distance is the wrong one — arriving at a town, which wants a wider view than a planet.
func watch(index: int, frame_radius: float, guard_radius: float, from_point: Vector3,
		framing: float = FOCUS_ZOOM) -> void:
	_begin_travel(from_point)
	anchor_body = index
	zoom = clamp_zoom(frame_radius * framing, guard_radius)


## Turn so that [param direction] — an outward direction on the subject's surface — faces the camera.
##
## This is what "centre on that town" means on a sphere: you cannot put a point on a globe in the middle
## of the screen by moving the camera sideways, you have to rotate the globe until the point is the part
## turned towards you. Animated, like the travel it accompanies: snapping a quarter-turn between two
## frames tells you nothing about which way the world just went.
func aim_from(direction: Vector3) -> void:
	if direction.length_squared() <= 0.0:
		return
	var dir: Vector3 = direction.normalized()
	_from_yaw = facing_yaw()
	_from_pitch = facing_pitch()
	pitch = clampf(asin(clampf(dir.y, -1.0, 1.0)), -PITCH_LIMIT, PITCH_LIMIT)
	yaw = atan2(dir.x, dir.z)
	_angle_blend = 0.0


## The orientation to DRAW at, as opposed to the one being headed for.
##
## Interpolated the short way round: from 175° to −175° is ten degrees, not three hundred and fifty, and
## a camera that took the long way would swing right past the thing it was asked to look at.
func facing_yaw() -> float:
	if _angle_blend >= 1.0:
		return yaw
	return _from_yaw + angle_difference(_from_yaw, yaw) * _ease(_angle_blend)


func facing_pitch() -> float:
	if _angle_blend >= 1.0:
		return pitch
	return lerpf(_from_pitch, pitch, _ease(_angle_blend))


## Carry the view along by [param rotation], keeping whatever angle the user has chosen.
##
## This is how a place is FOLLOWED. Re-aiming at it outright would work and would be useless: it would
## undo the orbit gesture every frame, so you could never look at a town from the side. Applying the
## rotation the place itself has just undergone moves the camera exactly as much as the ground did, and
## leaves the offset you orbited to untouched.
##
## Refused while a travel is in flight: an animated turn is already going somewhere, and steering it a
## degree at a time would fight it for the wheel.
func turn_by(rotation: Quaternion) -> void:
	if _angle_blend < 1.0:
		return
	var dir: Vector3 = (rotation * direction()).normalized()
	if dir.length_squared() <= 0.0:
		return
	pitch = clampf(asin(clampf(dir.y, -1.0, 1.0)), -PITCH_LIMIT, PITCH_LIMIT)
	yaw = atan2(dir.x, dir.z)


## Back to the view the chart opens on: the whole system, nothing followed, default orientation. This
## is what the button does, and it is the ONLY thing that throws the camera across the system.
func reset(from_point: Vector3) -> void:
	_begin_travel(from_point)
	anchor = Vector3.ZERO
	anchor_body = 0
	focus = -1
	focus_key = ""
	zoom = DEFAULT_ZOOM
	_from_yaw = facing_yaw()
	_from_pitch = facing_pitch()
	yaw = DEFAULT_YAW
	pitch = DEFAULT_PITCH
	_angle_blend = 0.0


func advance(delta: float) -> void:
	var step: float = delta / TRANSITION_S
	_point_blend = minf(1.0, _point_blend + step)
	_zoom_blend = minf(1.0, _zoom_blend + step)
	_angle_blend = minf(1.0, _angle_blend + step)


func is_travelling() -> bool:
	return _point_blend < 1.0 or _zoom_blend < 1.0 or _angle_blend < 1.0


## Where the camera should aim this frame. [param live_target] is read fresh every frame rather than
## captured on click, because the subject is moving — that is what makes "follow this planet" work at
## all — and the travel only blends the START of the move away.
func look_point(live_target: Vector3) -> Vector3:
	if _point_blend >= 1.0:
		return live_target
	return _from_point.lerp(live_target, _ease(_point_blend))


## The distance to draw at. Interpolated in the LOG domain: a chart running from ten thousand km to
## eight billion cannot blend a distance linearly. Half way through, a linear blend from 1200 to 0.02 is
## still at 600 — the entire visible part of the move would be crammed into the last few frames.
func distance() -> float:
	if _zoom_blend >= 1.0:
		return zoom
	var from: float = maxf(_from_zoom, ZOOM_MIN)
	var goal: float = maxf(zoom, ZOOM_MIN)
	return exp(lerp(log(from), log(goal), _ease(_zoom_blend)))


## Unit vector from the subject to the camera, in the chart's world.
func direction() -> Vector3:
	var turn: float = facing_yaw()
	var lift: float = facing_pitch()
	return Vector3(cos(lift) * sin(turn), sin(lift), cos(lift) * cos(turn))


func _begin_travel(from_point: Vector3) -> void:
	_from_point = from_point
	# From where the camera ACTUALLY is, so interrupting one travel with another continues from the
	# visible position instead of teleporting to the abandoned goal first.
	_from_zoom = distance()
	_point_blend = 0.0
	_zoom_blend = 0.0


## Cubic ease-out: quick off the mark, so the move answers the click at once, then settling rather than
## stopping dead.
static func _ease(t: float) -> float:
	var inv: float = 1.0 - clampf(t, 0.0, 1.0)
	return 1.0 - inv * inv * inv
