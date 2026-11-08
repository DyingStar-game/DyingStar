extends "res://scenes/planet/lava/lava_fixed_core.gd"
## Client/offline presentation adapter. Network peers send canonical integer
## terrain, parameters and tick commands to lava_fixed_core.gd, never these
## floating-point convenience inputs or presentation arrays.

const MAX_DT := 0.1
var presentation_enabled := true
var _view_initialized := false
var visual_dirty := PackedInt32Array()
var _visual_dirty_mask := PackedByteArray()
var cell_m := 0.0
var bed := PackedFloat64Array()
var depth := PackedFloat64Array()
var temperature := PackedFloat64Array()
var age := PackedFloat64Array()
var velocity := PackedVector2Array()
var positions := PackedVector2Array()
var opacity := PackedFloat32Array()
var radial_centres := PackedFloat32Array()
var elapsed_s := 0.0
var injected_m3 := 0.0
var viscosity_pa_s: float:
	get: return viscosity_q
	set(value):
		if is_finite(value): viscosity_q = roundi(clampf(value, 1.0, 100000.0))
var yield_pa: float:
	get: return yield_q
	set(value):
		if is_finite(value): yield_q = roundi(clampf(value, 0.0, 1000000000.0))


func configure_q(nx: int, nz: int, spacing_mm: int, terrain: PackedInt64Array) -> bool:
	var accepted := super.configure_q(nx, nz, spacing_mm, terrain)
	if accepted:
		_view_initialized = false
	return accepted


func configure(nx: int, nz: int, spacing: float, terrain: PackedFloat64Array) -> bool:
	if not is_finite(spacing) or spacing < 1.0 or spacing > 64.0:
		return false
	var canonical := PackedInt64Array()
	for value in terrain:
		if not is_finite(value) or absf(value) > 10000.0:
			return false
		canonical.append(roundi(value * 1000.0))
	if not configure_q(nx, nz, roundi(spacing * 1000.0), canonical):
		return false
	refresh_views()
	return true


func inject_disc(center: Vector2, radius_m: float, volume_m3: float, celsius: float) -> void:
	if not is_finite(volume_m3) or volume_m3 <= 0.0 or volume_m3 > 1000000.0:
		return
	if not is_finite(celsius) or not is_finite(radius_m) or radius_m <= 0.0 or radius_m > 8192.0:
		return
	if not is_finite(center.x) or not is_finite(center.y) or absf(center.x) > 16384.0 or absf(center.y) > 16384.0:
		return
	var commands := disc_commands(roundi(center.x * 1000.0), roundi(center.y * 1000.0),
		roundi(radius_m * 1000.0), roundi(volume_m3 * Q_PER_M3), roundi(celsius * 10.0))
	if inject_q(commands):
		refresh_views()


func advance_tick(expected_tick: int, commands: PackedInt64Array = PackedInt64Array()) -> bool:
	if not super.advance_tick(expected_tick, commands):
		return false
	if presentation_enabled:
		refresh_views(false)
	return true


func step(dt: float) -> bool:
	# No variable timestep in the authoritative model.
	return is_finite(dt) and dt == MAX_DT and advance_tick(tick + 1)


func viscosity_at(celsius: float) -> float:
	return mu_at(roundi(celsius * 10.0))


func restore(bytes: PackedByteArray) -> bool:
	if not super.restore(bytes):
		return false
	if presentation_enabled:
		refresh_views()
	return true


func refresh_views(full: bool = true) -> void:
	cell_m = cell_mm / 1000.0
	var count := volume_q.size()
	if not _view_initialized or bed.size() != count:
		bed.resize(count); depth.resize(count); temperature.resize(count)
		age.resize(count); velocity.resize(count); positions.resize(count); opacity.resize(count)
		depth.fill(0.0); temperature.fill(20.0); age.fill(0.0); velocity.fill(Vector2.ZERO); opacity.fill(1.0)
		radial_centres.clear()
		if geometry_mode == 1:
			for z in height: radial_centres.append((radial_edges_mm[z] + radial_edges_mm[z + 1]) / 2000.0)
		for i in count:
			bed[i] = terrain_q[i] / 1000.0
			if geometry_mode == 1:
				var angle := (i % width + 0.5) * TAU / width
				positions[i] = Vector2(cos(angle), sin(angle)) * radial_centres[i / width]
			else: positions[i] = Vector2(i % width, i / width) * cell_m
		_view_initialized = true
		_visual_dirty_mask.resize(count); _visual_dirty_mask.fill(0)
		visual_dirty.clear()
		full = true
	for i in cleared_indices:
		depth[i] = 0.0; temperature[i] = 20.0; age[i] = 0.0; velocity[i] = Vector2.ZERO; opacity[i] = 0.0
		_mark_visual_dirty(i)
	var updated: PackedInt32Array = wet_indices if full else changed_indices
	for i in updated:
		if volume_q[i] == 0: continue
		_mark_visual_dirty(i)
		depth[i] = volume_q[i] * 1000.0 / areas_q[i]
		opacity[i] = fade_ticks_q[i] / float(FADE_DURATION_TICKS) if fade_ticks_q[i] > 0 else 1.0
		temperature[i] = 20.0 + current_energy_q(i) / (float(volume_q[i]) * 10.0)
		age[i] = current_exposure_q(i) / (float(volume_q[i]) * 10.0)
		velocity[i] = Vector2(vx_q[i], vz_q[i]) / 1000000.0
		if geometry_mode == 1:
			var radial := positions[i].normalized()
			velocity[i] = Vector2(-radial.y, radial.x) * velocity[i].x + radial * velocity[i].y
	elapsed_s = tick / 10.0
	injected_m3 = injected_q / float(Q_PER_M3)


func diagnostics() -> Dictionary:
	var total := 0
	var heat := 0
	var wet := 0
	var frozen := 0
	var max_depth := 0.0
	for i in volume_q.size():
		total += volume_q[i]
		heat += current_energy_q(i)
		max_depth = maxf(max_depth, volume_q[i] * 1000.0 / areas_q[i])
		if volume_q[i] * 1000000 > areas_q[i] * 3:
			wet += 1
			if current_energy_q(i) / volume_q[i] + AMBIENT_T <= SOLIDUS_T:
				frozen += 1
	return {"volume_m3": total / float(Q_PER_M3), "volume_q": total, "injected_m3": injected_q / float(Q_PER_M3),
		"heat_proxy": heat / (Q_PER_M3 * 10.0), "heat_q": heat, "wet_cells": wet, "frozen_cells": frozen,
		"max_depth_m": max_depth, "elapsed_s": tick / 10.0, "tick": tick, "limited_cells": limited_cells, "removed_m3": removed_q / float(Q_PER_M3)}


func release_views() -> void:
	presentation_enabled = false
	_view_initialized = false
	bed.clear(); depth.clear(); temperature.clear(); age.clear(); velocity.clear()
	positions.clear(); opacity.clear(); radial_centres.clear()
	visual_dirty.clear(); _visual_dirty_mask.clear()


func _mark_visual_dirty(i: int) -> void:
	if _visual_dirty_mask[i] == 0:
		_visual_dirty_mask[i] = 1
		visual_dirty.append(i)


func take_visual_dirty() -> PackedInt32Array:
	var result := visual_dirty
	visual_dirty = PackedInt32Array()
	for i in result: _visual_dirty_mask[i] = 0
	return result
