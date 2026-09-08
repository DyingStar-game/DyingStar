class_name StepProbe
extends RefCounted

## Geometric step probe, shared (DRY) by the server that ACTS on it (PlayerServer._try_start_step_up)
## and the owner's debug HUD that just SHOWS it — the same arrangement as VaultProbe, and for the same
## reason: a readout with geometry of its own would drift from the thing it claims to measure.
##
## A step is what you walk up without asking: an obstacle BELOW the vault threshold, with a walkable
## top and room for the body on it. Godot's CharacterBody3D will not climb one on its own.
##
## RISE, ADVANCE, DROP — with the body's OWN collider, not with rays. The body is lifted by the step
## limit, pushed forward, and dropped back down; where it lands is the step, and how far it fell short
## of the lift is the step's height. It is what Unreal's CharacterMovementComponent::StepUp does, and
## the reason to prefer it here is not fashion:
##
##   • A ray samples a POINT. Whether it hits depends on where that one point falls on the obstacle —
##     a chamfered edge, a joint between two meshes, a grating, a lip thinner than the ray is precise.
##     That is how a 0.18 m step could be refused while a 0.21 m one was climbed: nothing to do with
##     height, everything to do with what the single sample happened to touch. A swept shape integrates
##     over the whole contact area and cannot fall down that gap.
##   • The previous version needed a horizontal ray to hit a FACE before it would look for a top, while
##     VaultProbe finds its surface by casting DOWN and needs no face at all. So the two disagreed by
##     construction: an obstacle whose face was missed was invisible to the step-up and plain to the
##     vault. Measured in game, at a standstill: "can vault: 0.18m" and "can step: clear", same frame.
##   • The magic numbers are gone. There is no ray height to choose, no fixed nudge past the face, no
##     assumption about where the body origin sits inside the capsule. The collider IS the geometry, so
##     the probe cannot disagree with the body it is supposed to describe.
##
## Returns { "ok", "height", "landing" (WORLD), "face_dist", "reason" }. The height is filled in
## whenever a top was found, even when the step is refused, so the HUD can show WHAT is in front and
## WHY it was turned down. Reasons: "clear" (nothing ahead) / "tall" (blocked even once lifted, so it
## is the vault's business or a wall) / "no headroom" (not enough room above to lift the body at all) /
## "no top" / "too low" / "too tall" / "ok". It also reports the
## surface orientation it measured ("flatness", "edge_flatness", "surface") -- for the log only: see
## step 3 for why no verdict is taken on it.
##
## NOTE the server's probe hits full collision; the client's sees PROPS but not the server-only
## terrain, so the HUD reading is exact against crates and structures and blank against terrain steps.

## Below this, the "step" is ground noise rather than an obstacle.
const MIN_HEIGHT: float = 0.03
## The lift must clear the obstacle by this much before we try to move over it, or a body wedged under
## a ceiling would "rise" a millimetre and call the result a step.
const MIN_CLEARANCE: float = 0.02
## And it must actually get somewhere once lifted. Below this the way is blocked at every height: a
## wall, not a step.
const MIN_ADVANCE: float = 0.02
## Lifts to try, as fractions of max_step, SMALLEST FIRST. Ascending so the body is made no taller than
## the obstacle actually requires, and a low doorway stops costing us the step behind it.
const LIFT_FACTORS: Array[float] = [0.25, 0.5, 1.0]
## Extra drop allowed on the way back down, so a step measured at exactly the limit still finds ground.
const DROP_MARGIN: float = 0.05
## Half-length of the little ray that reads the surface orientation under the landing.
const NORMAL_PROBE: float = 0.05


## Probe from `body` (a Player) along `move_dir`. `max_step` is the vault threshold: at or above it the
## obstacle stops being a step.
static func probe(body, move_dir: Vector3, max_step: float) -> Dictionary:
	var result: Dictionary = {
		"ok": false, "height": 0.0, "landing": Vector3.ZERO, "face_dist": 0.0, "reason": "clear",
		"flatness": 1.0, "edge_flatness": 1.0, "surface": "", "rise": 0.0,
	}
	var world: World3D = body.get_world_3d()
	if world == null:
		return result
	if world.direct_space_state == null:
		return result  # only valid during physics — never crash from an idle frame
	var up: Vector3 = body.up_direction
	var fwd: Vector3 = move_dir - up * move_dir.dot(up)
	if fwd.length() < 0.01:
		return result
	fwd = fwd.normalized()

	var xf: Transform3D = body.global_transform
	var reach: float = body.step_up_reach

	# 1 + 2. LIFT AS LITTLE AS NECESSARY, then advance.
	#
	# The lift is a MEANS, not an end. Raising the whole body by max_step turns a 1.8 m body into a 2.3 m
	# one, and it then has to fit through the very opening it was about to walk through. Measured in game,
	# in a doorway: the rise was clipped to 0.434 by the lintel, and the advance was then blocked at 0.001
	# by the wall ABOVE the door. A 7 cm step, refused because the body had been made too tall for the door.
	#
	# So try the smallest lift first and grow only while the way is blocked. A 7 cm step needs a 7 cm lift,
	# which passes under any lintel a walking body already passes under; only a genuinely tall step ever
	# needs the full max_step, and only then do we pay for the extra sweeps.
	var rise: float = 0.0
	var advance: float = 0.0
	var lifted: Transform3D = xf
	for factor in LIFT_FACTORS:
		lifted = xf
		rise = _sweep(body, lifted, up * (max_step * factor))
		result["rise"] = rise
		if rise < MIN_CLEARANCE:
			result["reason"] = "no headroom"
			return result  # nothing above us at all: a ceiling, not a step
		lifted.origin += up * rise
		advance = _sweep(body, lifted, fwd * reach)
		result["face_dist"] = advance  # set BEFORE the test: a refusal reports the number it refused on
		if advance >= MIN_ADVANCE:
			break
	if advance < MIN_ADVANCE:
		result["reason"] = "tall"  # blocked at every lift up to max_step: a wall, or the vault to do
		return result
	xf = lifted
	xf.origin += fwd * advance

	# 3. DROP. Fall back down; what stops us is the surface we would stand on. Falling the whole way
	# means there was nothing there — we were leaning over a ledge, not standing in front of a step.
	var collision := KinematicCollision3D.new()
	if not body.test_move(xf, -up * (rise + DROP_MARGIN), collision):
		result["reason"] = "no top"
		return result
	var drop: float = collision.get_travel().length()

	# The step's height is what the drop failed to give back.
	var height: float = rise - drop
	result["height"] = height
	var landing: Vector3 = xf.origin - up * drop

	# Which way does the surface face, measured two ways: a short ray straight down through the point the
	# body would stand on, and the capsule's own contact. They disagree on terrain (1.00 against 0.50 --
	# a rounded capsule landing near an edge touches the CORNER, whose normal describes the corner and
	# not the ground) and agree on built geometry. Reported, never used as a verdict: see below.
	var flat: Dictionary = world.direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(landing + up * NORMAL_PROBE, landing - up * NORMAL_PROBE,
			Globals.MASK_OBSTACLE, [body.get_rid()]))
	var normal: Vector3 = Vector3(flat["normal"]) if not flat.is_empty() else collision.get_normal(0)
	# Both readings and what was hit, for the log: when a step is refused as steep, the only way to tell a
	# genuinely steep surface from a normal read off the wrong thing is to see the number and the name.
	result["flatness"] = normal.dot(up)
	result["edge_flatness"] = collision.get_normal(0).dot(up)
	var hit_node = flat.get("collider") if not flat.is_empty() else collision.get_collider(0)
	result["surface"] = String(hit_node.name) if hit_node is Node else "(rayon dans le vide)"
	# NO flatness verdict. Measured in game on a staircase: the same step, at the same height, was
	# refused at 0.60 and climbed at 0.60 -- every reading crowded against the threshold (0.50 · 0.55 ·
	# 0.57 · 0.58 · 0.59 · 0.60 · 0.62) and fell either side of it on rounding. A single normal, whether
	# read from a ray or from the contact, describes ONE triangle of a bevelled or tessellated top; it
	# does not answer "can I stand up there", and pretending it does turned the decision into a coin flip.
	#
	# The two things it was meant to prevent are already covered, and covered volumetrically:
	#   • walking into a WALL -> the ADVANCE stops dead, which is the "tall" verdict above;
	#   • ending up on a slope too steep to hold -> that is floor_max_angle, and move_and_slide applies
	#     it one frame later, on the real body, far better than we can guess here.
	# The value is still measured and logged, because it is worth seeing; it just no longer decides.
	if height <= MIN_HEIGHT:
		result["reason"] = "too low"
		return result
	if height > max_step:
		result["reason"] = "too tall"
		return result

	# The landing is measured, not reconstructed: it is where the swept body actually came to rest, so
	# it cannot disagree with the collider that will have to fit there a moment later.
	result["landing"] = landing
	result["ok"] = true
	result["reason"] = "ok"
	return result


## How far the body can travel from `xf` along `motion` before its own collider is stopped. Returns the
## full length when nothing is in the way.
##
## test_move() and not a ray: it sweeps the REAL capsule, which is the whole point of this probe.
static func _sweep(body, xf: Transform3D, motion: Vector3) -> float:
	var collision := KinematicCollision3D.new()
	if not body.test_move(xf, motion, collision):
		return motion.length()
	return collision.get_travel().length()
