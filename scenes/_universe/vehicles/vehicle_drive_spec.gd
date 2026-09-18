class_name VehicleDriveSpec
extends RefCounted

## Drive SIZING for a Vehicle (SRP): turns the engines actually fitted, plus the chassis numbers,
## into what the drivetrain needs — tractive force, top speed, climbable slope, acceleration.
## Pure maths, no scene nodes: the Vehicle owns one, refills it when its engines change, and
## reads the results. Sibling of VehiclePowertrain, which handles the per-frame force curve and
## is fed FROM here.
##
## This is the game-side twin of the design spreadsheet: every method below is one of its rows,
## and the two must keep agreeing. A disagreement would raise no error, it would just produce a
## truck that does not drive the way it was designed — so test/unit/test_vehicle_drive_spec.gd
## pins the reference vehicles.
##
## SIZING, NOT SIMULATION. These are the EQUILIBRIUM values a vehicle settles at, the answer to
## "how fast can it end up going", not "what force is applied this frame".
##
## Units are SI throughout (W, N, Nm, m, m/s, rad, kg). Only the HUD converts to km/h.
##
## EMPTY IS A VALID STATE. A vehicle with no engine fitted does not move, and every getter here
## returns 0 instead of dividing by zero.

# --- What is fitted -------------------------------------------------------------------------
## The engines actually bolted in. They SUM: two motors pull twice as hard. Note what that does
## NOT do — see omega_max_rads().
var motors: Array[VehicleEngineSpec] = []

# --- Chassis --------------------------------------------------------------------------------
## Driven wheel radius (m). It sets BOTH the top speed (omega * r) and the tractive force
## (torque / r), which is why the Vehicle passes its own wheel_radius in rather than anyone
## typing the number twice: the two would drift apart and nothing would complain.
var wheel_radius: float = 0.3
## Transmission losses, downstream of the motor's own efficiency. The spreadsheet splits them
## into a pump and a hydraulic stage; both belong to the chassis, not to the engine.
var pump_efficiency: float = 0.8
var hydraulic_efficiency: float = 0.8
## Fixed gearing of the chassis: how its transmission trades speed for pull. A hauler uses a
## high factor (more torque, less speed), a buggy a low one. Applied to TORQUE only.
var torque_factor: float = 1.0
## Aerodynamics: drag coefficient and frontal area (m2).
var drag_coefficient: float = 1.0
var frontal_area: float = 3.0
## Rolling resistance of the ground (0.001 on good road, 0.3 on soft sand) and the tyre
## correction on top of it.
var rolling_coefficient: float = 0.01
var rolling_factor: float = 1.0

# --- Environment ----------------------------------------------------------------------------
## Air density (kg/m3) and gravity (m/s2) where the vehicle stands. Gravity comes from the
## physics engine itself (Vehicle reads state.total_gravity), so climbing is harder on a heavy
## world for free. Defaults are Sandbox's.
var air_density: float = 1.26
var gravity: float = 6.867


# ── Engine side ───────────────────────────────────────────────

## True when there is anything to drive with. Everything else returns 0 when this is false.
func is_valid() -> bool:
	return not motors.is_empty() and mech_torque_nm() > 0.0

## Number of engines fitted (the HUD wants it, and so does anyone reading a log).
func motor_count() -> int:
	return motors.size()

## Mechanical power at the wheels (W): each motor's shaft power, then the chassis's own losses.
func mech_power_w() -> float:
	var shaft: float = 0.0
	for m in motors:
		if m != null:
			shaft += m.shaft_power_w()
	return shaft * pump_efficiency * hydraulic_efficiency

## Mechanical torque at the wheels (Nm). Deliberately NOT multiplied by the efficiencies: the
## spreadsheet applies the losses to power only. Keeping that asymmetry is what makes the top
## speed come out where it designed it to.
func mech_torque_nm() -> float:
	var total: float = 0.0
	for m in motors:
		if m != null:
			total += m.torque_nm
	return total * torque_factor

## Angular speed at full power (rad/s) — where torque and power run out at the same time.
##
## NOTE, and it is the whole character of the model: both terms scale with the number of motors,
## so IT CANCELS. Fitting a second engine does NOT raise the top speed, it doubles the pull.
## Motors are a question of torque and payload, never of top speed; that one is set by the
## engine TIER (its power/torque ratio), the chassis torque_factor and the wheel radius.
func omega_max_rads() -> float:
	var torque: float = mech_torque_nm()
	if torque <= 0.0:
		return 0.0
	return mech_power_w() / torque

## Motor speed at top speed (rpm), for the gauge. Derived, so the needle cannot lie about an
## engine that is not the one fitted.
func motor_rpm_max() -> float:
	return omega_max_rads() * 60.0 / TAU

## Top speed the ENGINE allows (m/s), ground contact assumed.
func v_max_motor_ms() -> float:
	return omega_max_rads() * wheel_radius

## Tractive force at the tyre contact patch (N), before any resistance is taken off.
func tractive_force_n() -> float:
	if wheel_radius <= 0.0:
		return 0.0
	return mech_torque_nm() / wheel_radius


# ── Resistances and what is left ──────────────────────────────

## Rolling resistance (N) at a given total mass. Present at any speed, standing start included.
func rolling_force_n(total_mass: float) -> float:
	return rolling_coefficient * rolling_factor * total_mass * gravity

## Force actually available to accelerate or to climb (N). Never negative: an engine too weak to
## overcome its own rolling resistance simply goes nowhere.
func net_force_n(total_mass: float) -> float:
	return maxf(0.0, tractive_force_n() - rolling_force_n(total_mass))

## Steepest slope the vehicle can START on (rad) — measured at a standstill, so with no run-up
## and no dynamic friction, exactly as the design sheet defines it.
func max_slope_rad(total_mass: float) -> float:
	if total_mass <= 0.0 or gravity <= 0.0:
		return 0.0
	return asin(clampf(net_force_n(total_mass) / (total_mass * gravity), -1.0, 1.0))

## Top speed DRAG allows (m/s): where aerodynamic drag eats the whole net force.
func v_max_aero_ms(total_mass: float) -> float:
	var k: float = 0.5 * air_density * drag_coefficient * frontal_area
	if k <= 0.0:
		return INF
	return sqrt(net_force_n(total_mass) / k)

## Top speed, whichever of the two runs out first.
func v_max_ms(total_mass: float) -> float:
	return minf(v_max_motor_ms(), v_max_aero_ms(total_mass))

## Which of the two is the binding constraint — the sheet prints this, and it is worth printing
## because the answer tells you what to change to go faster.
func limiting_factor(total_mass: float) -> String:
	if not is_valid():
		return "NONE"
	return "MOTOR" if v_max_motor_ms() <= v_max_aero_ms(total_mass) else "AERO"

## Acceleration from a standstill (m/s2).
func max_acceleration(total_mass: float) -> float:
	if total_mass <= 0.0:
		return 0.0
	return net_force_n(total_mass) / total_mass

## Time to reach a given speed (s), at constant acceleration. The sheet's 0-100 and 0-Vmax.
## INF when the vehicle cannot move at all, which reads better in a HUD than a division error.
func time_to_speed(total_mass: float, target_ms: float) -> float:
	var acc: float = max_acceleration(total_mass)
	if acc <= 0.0:
		return INF
	return target_ms / acc
