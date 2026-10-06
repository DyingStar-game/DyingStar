class_name GodMode
extends RefCounted
## God mode: the dev free-flight (the `toggle_eva` key, '$' by default). Not the real EVA: the server
## flies the body where the camera looks, with no gravity and no collision, at a speed the mouse wheel
## sets — from a walk to crossing the system. The player's own weightlessness (no gravity area) is the
## real EVA, and keeps its thrusters.
##
## The speed is the owner's choice and the server's to apply: the client sends the speed it wants, the
## server clamps it again with these same bounds (next_speed), so a client cannot fly faster than this.

## Bounds of the flight speed, m/s: 1 m/s to place a camera, 100 000 km/s to reach a far planet.
const MIN_SPEED := 1.0
const MAX_SPEED := 1.0e8
## Each wheel notch doubles or halves it: 27 notches from one end to the other.
const NOTCH_FACTOR := 2.0
## Landing (`god_mode_land`, the middle mouse button): the body is set down this high above the ground
## under it, then falls the rest — the relief is sampled, and a body placed exactly on it can start
## a few centimetres under the triangles.
const LAND_CLEARANCE := 1.5


## The body a landing sets [param player] down on: the one whose gravity holds them — or, out of every
## gravity area, the one they belong to (Planet.of) — or null in open space. Client and server both ask
## it: the client only requests a landing the server will make.
static func landing_body(player) -> Planet:  # untyped: a Player, which cannot be named here (cycle)
	var gravity: Array = player.gravity_parents
	var body: Planet = Planet.of(gravity.back() if not gravity.is_empty() else player)
	return body if body != null and body.planet_data != null else null


## The speed after [param notches] wheel notches from [param speed] (positive = faster), within bounds.
static func next_speed(speed: float, notches: int) -> float:
	return clamp_speed(speed * pow(NOTCH_FACTOR, notches))


static func clamp_speed(speed: float) -> float:
	return clampf(speed, MIN_SPEED, MAX_SPEED)


## [param speed] as the HUD shows it: metres per second below a kilometre per second, then km/s.
static func speed_text(speed: float) -> String:
	if speed < 1000.0:
		return "%d m/s" % roundi(speed)
	var km := snappedf(speed / 1000.0, 0.1)
	return "%d km/s" % roundi(km) if is_equal_approx(km, roundf(km)) else "%.1f km/s" % km
