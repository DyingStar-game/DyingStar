class_name MachineSparks
extends Node3D

## CLIENT: the sparks of a broken machine (services ADR 0020): short bursts of bright points falling
## from where it stands, and a light that flashes with them. Built in code, off until set_running(true);
## nothing on a dedicated server. In its parent's frame (local coordinates): out where the planets are,
## world coordinates are metres off.

## Sparks per burst.
const AMOUNT := 28
## A burst's sparks live this long (s); the next burst comes when they are gone.
const LIFETIME_S := 0.7
## Seen from this far (m): a village's machines cost nothing from across it.
const VISIBLE_M := 60.0
const COLOUR := Color(1.0, 0.72, 0.25)
const LIGHT_ENERGY := 2.5
const LIGHT_RANGE_M := 5.0

var _particles: GPUParticles3D = null
var _light: OmniLight3D = null
var _flash: Tween = null


## Start or stop the sparks.
func set_running(on: bool) -> void:
	if GameOrchestrator.is_server():
		return
	if on and _particles == null:
		_build()
	if _particles == null or _particles.emitting == on:
		return
	_particles.emitting = on
	if _flash != null:
		_flash.kill()
		_flash = null
	_light.visible = on
	if on:
		# One flash per burst: up at once, down while the sparks fall.
		_flash = create_tween().set_loops()
		_flash.tween_property(_light, "light_energy", LIGHT_ENERGY, 0.04)
		_flash.tween_property(_light, "light_energy", 0.0, LIFETIME_S * 0.5)
		_flash.tween_interval(LIFETIME_S * 0.5 - 0.04)


func _build() -> void:
	var process := ParticleProcessMaterial.new()
	process.direction = Vector3.UP
	process.spread = 70.0
	process.initial_velocity_min = 1.5
	process.initial_velocity_max = 4.0
	process.gravity = Vector3(0.0, -9.8, 0.0)
	process.scale_min = 0.6
	process.scale_max = 1.2
	var dot := QuadMesh.new()
	dot.size = Vector2(0.035, 0.035)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = COLOUR
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	dot.material = material
	_particles = GPUParticles3D.new()
	_particles.amount = AMOUNT
	_particles.lifetime = LIFETIME_S
	_particles.explosiveness = 0.95
	_particles.randomness = 0.6
	_particles.local_coords = true
	_particles.process_material = process
	_particles.draw_pass_1 = dot
	_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_particles.visibility_range_end = VISIBLE_M
	_particles.emitting = false
	add_child(_particles)
	_light = OmniLight3D.new()
	_light.light_color = COLOUR
	_light.light_energy = 0.0
	_light.omni_range = LIGHT_RANGE_M
	_light.shadow_enabled = false
	_light.distance_fade_enabled = true
	_light.distance_fade_begin = VISIBLE_M * 0.5
	_light.distance_fade_length = VISIBLE_M * 0.5
	_light.visible = false
	add_child(_light)
