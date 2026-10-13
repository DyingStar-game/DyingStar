extends Node
## Throwaway probe: where a vehicle lift must stand to hang over a tarsis_3 canyon.
##
## The lift's frame (vehicle_lift_gizmo.gd): its origin sits on the cliff edge, +Z points over the
## void, the platform runs down -Y along the wall for descent_depth. From the lift's persisted pose,
## this finds the nearest canyon rim on the real crack network (organic CrackNoise, POI exclusions),
## the direction into the canyon and the canyon's depth there, and prints the pose to write back into
## horizonserver's startup_items.json.
##
## Run with:
##   godot --headless --path . res://test/parity/vehicle_lift_rim_probe.tscn
## LIFT_PROBE_POS="x,y,z" (planet-local m) to start from another lift.
## Output: user://vehicle_lift_rim_probe.txt

const PLANET_SCENE := "res://scenes/systems/tarsis/tarsis_3.tscn"
const LIFT_SCENE := "res://scenes/_universe/structures/industrial/vehicle_lift/vehicle_lift.tscn"
## The "Vehicle Lift Cargo" of startup_items.json, as persisted.
const LIFT_POS := Vector3(4450775.886, 2672442.484, 3676818.707)
const LIFT_ROT := Vector3(-0.972148, -3.028146, 0.675442)
## Forward-difference step of the edge-distance gradient (m).
const PROBE_M := 1.0

static var _out: FileAccess = null

var data: PlanetData


func say(t: String) -> void:
	if _out == null:
		_out = FileAccess.open("user://vehicle_lift_rim_probe.txt", FileAccess.WRITE)
	_out.store_line(t)
	_out.flush()
	print(t)


func _ready() -> void:
	var pos := LIFT_POS
	var env := OS.get_environment("LIFT_PROBE_POS")
	if env != "":
		var p := env.split(",")
		pos = Vector3(float(p[0]), float(p[1]), float(p[2]))
	var body: Node = (load(PLANET_SCENE) as PackedScene).instantiate()
	data = body.get("planet_data")
	data.apply_chunk_manifest()
	data.remote_source = RemoteTileSource.for_planet(data.planet_name)
	data.warm_mountains()
	data.set_crack_exclusions(PlanetTerrain.poi_crack_exclusions(data.planet_name))
	say("PROBE %s radius=%.0f spacing=%.0f width=%.0f depth=%.0f tiles=%s" % [data.planet_name,
			data.radius, data.crack_spacing_m, data.crack_width_m, data.crack_depth_m,
			"none" if data.remote_source == null else data.remote_source.base_url])
	_lift_extents()

	var dir0 := pos.normalized()
	var half := data.crack_width_m * 0.5
	var d0 := _d(dir0)
	var ground0 := data.crack_aware_surface_dist(dir0)
	say("PROBE current lift: edge dist %.2f m (rim at %.1f), |pos| - ground = %.3f m, lat %.5f lon %.5f"
			% [d0, half, pos.length() - ground0, rad_to_deg(asin(dir0.y)), rad_to_deg(atan2(-dir0.z, dir0.x))])
	var cur_basis := Basis.from_euler(LIFT_ROT)
	say("PROBE current basis: up·radial %.5f, +Z = %s" % [cur_basis.y.dot(dir0), str(cur_basis.z)])

	# Newton on the tangent plane towards d = half (the rim), as the chunk builders' rim snap does.
	var dir := dir0
	for i in 40:
		var d := _d(dir)
		if absf(d - half) < 0.02:
			break
		var g := _grad(dir)
		if g.length_squared() < 1e-6:
			say("PROBE vanishing gradient at step %d" % i)
			break
		var step_m := clampf((d - half) / g.length_squared(), -25.0, 25.0)
		dir = (dir * data.radius - g * step_m).normalized()
	var rim := dir
	var into := -_grad(rim).normalized()  # decreasing distance: into the canyon
	say("PROBE rim: edge dist %.3f m, moved %.1f m from the lift, depth factor %.3f"
			% [_d(rim), (rim - dir0).length() * data.radius, CrackCarve.depth_factor(data, rim, null)])

	# How straight the rim is under the lift: the edge distance along the rim, ±12 m.
	var along := rim.cross(into).normalized()
	var line := []
	for s in [-12.0, -6.0, 6.0, 12.0]:
		line.append("%+.0f m: %.2f" % [s, _d((rim * data.radius + along * s).normalized()) - half])
	say("PROBE rim straightness (edge dist - half): %s" % ", ".join(line))

	# Plateau beside the rim and canyon floor past the foot.
	var plateau := data.crack_aware_surface_dist((rim * data.radius - into * 3.0).normalized())
	var at_rim := data.crack_aware_surface_dist(rim)
	var floor_r := data.crack_aware_surface_dist((rim * data.radius + into * 20.0).normalized())
	say("PROBE plateau %.2f m, at rim %.2f m, floor (20 m in) %.2f m → depth %.2f m"
			% [plateau - data.radius, at_rim - data.radius, floor_r - data.radius, plateau - floor_r])

	# The lift's pose: Y radial, +Z over the void, origin on the rim at plateau level (with the same
	# height above the ground as the persisted pose had).
	var y := rim
	var z := (into - y * into.dot(y)).normalized()
	var x := y.cross(z)
	var b := Basis(x, y, z).orthonormalized()
	var lift_pos := rim * (plateau + (pos.length() - ground0))
	var e := b.get_euler()
	say("PROBE NEW position {\"x\": %.3f, \"y\": %.3f, \"z\": %.3f}" % [lift_pos.x, lift_pos.y, lift_pos.z])
	say("PROBE NEW rotation {\"x\": %.6f, \"y\": %.6f, \"z\": %.6f}" % [e.x, e.y, e.z])
	say("PROBE NEW descent_depth %.1f" % (plateau - floor_r))
	say("PROBE check: euler round trip error %.9f m" % (Basis.from_euler(e).z - z).length())
	body.free()
	get_tree().quit()


## Edge distance (m) to the nearest crack rim line at [param dir], as the full-detail collision sees it.
func _d(dir: Vector3) -> float:
	return ArideDesertCorundumPlateauTerrain.crack_edge_distance_m(dir, data.radius,
			data.crack_spacing_m, data.crack_width_m, 0.0, data.crack_noise())


## Gradient of [method _d] on the tangent plane at [param dir] (m per m, planet-local).
func _grad(dir: Vector3) -> Vector3:
	var e1 := dir.cross(Vector3.UP if absf(dir.y) < 0.9 else Vector3.RIGHT).normalized()
	var e2 := dir.cross(e1)
	var p := dir * data.radius
	var d := _d(dir)
	var gx := (_d((p + e1 * PROBE_M).normalized()) - d) / PROBE_M
	var gy := (_d((p + e2 * PROBE_M).normalized()) - d) / PROBE_M
	return e1 * gx + e2 * gy


## Where each part of the lift's scene stands along its local Z (the axis over the void).
func _lift_extents() -> void:
	var lift: Node3D = (load(LIFT_SCENE) as PackedScene).instantiate()
	for child in lift.get_children():
		if not child is Node3D:
			continue
		var box := AABB()
		var first := true
		for shape_node in child.find_children("*", "CollisionShape3D", true, false):
			var cs := shape_node as CollisionShape3D
			if cs.shape == null:
				continue
			var xf := Transform3D.IDENTITY
			var n: Node = cs
			while n != lift:
				xf = (n as Node3D).transform * xf
				n = n.get_parent()
			var bb: AABB = xf * cs.shape.get_debug_mesh().get_aabb()
			box = bb if first else box.merge(bb)
			first = false
		if not first:
			say("PROBE lift part %-16s z %.2f .. %.2f  x %.2f .. %.2f  y %.2f .. %.2f" % [child.name,
					box.position.z, box.end.z, box.position.x, box.end.x, box.position.y, box.end.y])
	lift.free()
