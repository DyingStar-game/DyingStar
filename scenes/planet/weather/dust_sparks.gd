class_name DustSparks
extends Node3D
## The sparks of static of one dust wall: the grains rub and charge, and the thick of a strong wall flashes.
## Each spark is a thin crooked arc (dust_bolt.gdshader) standing just behind the wall's front for an
## instant, flickering, and a glow in the dust round it (the wall's volume reads the sparks alight from its
## material's "sparks").
##
## Lives beside the wall's box, in the same frame (WeatherPhenomena's). Nothing done to anyone, and not the
## same sparks for two players. Each strike is heard (crackle): a dry, muffled snap inside the dust, no thunder
## (WarpZone, dust-lightning-far-*.ogg), late by its distance at the speed of sound, duller farther away.

const BOLT_SHADER := preload("res://scenes/planet/weather/dust_bolt.gdshader")
## The strikes' sounds (loaded when first needed: a file the editor has not imported yet is skipped).
const CRACKLES: Array[String] = [
	"res://assets/_universe/audio/sfx/environment/weather/dust-lightning-far-1.ogg",
	"res://assets/_universe/audio/sfx/environment/weather/dust-lightning-far-2.ogg",
	"res://assets/_universe/audio/sfx/environment/weather/dust-lightning-far-3.ogg",
	"res://assets/_universe/audio/sfx/environment/weather/dust-lightning-far-4.ogg",
]
## The speed of sound (m/s): a strike is heard this late after it is seen.
const SOUND_M_S := 343.0
## A strike's loudness (dB) at CRACKLE_NEAR_M, fading as 1/d past it, not heard past CRACKLE_FAR_M; its
## pitch strays by up to CRACKLE_PITCH either way; a low-pass from CRACKLE_CUTOFF_HZ.x (near) down to
## CRACKLE_CUTOFF_HZ.y at CRACKLE_FAR_M: crisp close, muffled far.
const CRACKLE_DB := 0.0
const CRACKLE_NEAR_M := 150.0
const CRACKLE_FAR_M := 4000.0
const CRACKLE_PITCH := 0.1
const CRACKLE_CUTOFF_HZ := Vector2(9000.0, 900.0)
## Sparks alight at once at most (the wall's volume shader holds as many: its SPARKS).
const COUNT := 5
## A spark waits between these (s) before it strikes again, and lasts between these.
const WAIT_S := Vector2(0.6, 3.2)
const LAST_S := Vector2(0.1, 0.28)
## How tall an arc is (m, from and to) and how wide its quad is over its height.
const TALL_M := Vector2(180.0, 520.0)
const WIDE := 0.7
## An arc stands between these distances behind the front (m: deeper, the dust would hide it), its foot
## between these shares of the wall's height, along the front up to WINDOW_M from the eye.
const BEHIND_M := Vector2(15.0, 110.0)
const FOOT := Vector2(0.05, 0.6)
const WINDOW_M := 6000.0
## Sparks strike when the wall is at least this strong, and no more once it is this far spent.
const MIN_STRENGTH := 0.35
const MAX_SPENT := 0.8
## A spark alight flickers between these brightnesses, changing this often (s).
const FLICKER := Vector2(0.35, 1.0)
const FLICKER_S := 0.035
## The glow a spark lights in the dust round it fades by e every GLOW_S (s) from its strike: a brief flash
## in the dust, while the arc itself stays alight its whole LAST_S (at its full flicker, the dust round it
## glowed as long as the arc, 2026-11-25).
const GLOW_S := 0.05

## How much of the open air the eye is in (WeatherPhenomena): no spark is seen from under the ground.
var open_air := 1.0

var _box: Node3D
var _material: ShaderMaterial
var _bolt_material: ShaderMaterial
var _bolts: Array[MeshInstance3D] = []
var _next := PackedFloat64Array()  # when each spark strikes again
var _until := PackedFloat64Array()  # until when it is alight
var _struck := PackedFloat64Array()  # when it struck
var _bright := PackedFloat32Array()  # its flicker now
var _where: Array[Vector3] = []  # where it stands, metres in the box's frame
var _clock := 0.0
var _flicker_at := 0.0
var _lit := PackedVector4Array()
static var _crackles: Array[AudioStream] = []


## Sparks for the wall drawn by [param box] (its scaled box node) with [param material] (its volume
## material); [param noise]: the arcs' crookedness.
func setup(box: Node3D, material: ShaderMaterial, noise: Texture2D) -> void:
	_box = box
	_material = material
	var bolt_material := ShaderMaterial.new()
	_bolt_material = bolt_material
	bolt_material.shader = BOLT_SHADER
	bolt_material.set_shader_parameter("noise", noise)
	bolt_material.render_priority = 1  # over the wall's volume
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	for k in COUNT:
		var bolt := MeshInstance3D.new()
		bolt.mesh = quad
		bolt.material_override = bolt_material
		bolt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		bolt.visible = false
		add_child(bolt)
		_bolts.append(bolt)
		_next.append(randf_range(0.0, WAIT_S.y))
		_until.append(0.0)
		_struck.append(0.0)
		_bright.append(0.0)
		_where.append(Vector3.ZERO)
	_lit.resize(COUNT)


## The arcs seen through the dust sea as it is now (DustSea.light_material), the fog taking [param fog_share] of
## its extinction (WeatherPhenomena.SEA_FOG_SHARE).
func sea(fog_share: float) -> void:
	if _bolt_material != null:
		DustSea.light_material(_bolt_material)
		_bolt_material.set_shader_parameter("sea_fog_share", fog_share)


## The sound of a strike at [param at] (this node's frame) for an eye at [param eye] (same frame), its take and
## pitch drawn from [param bolt_seed]: late by the distance, fainter and duller with it.
func crackle(at: Vector3, eye: Vector3, bolt_seed: float) -> void:
	if Sfx3D.muted():
		return
	if _crackles.is_empty():
		for path: String in CRACKLES:
			if ResourceLoader.exists(path):
				_crackles.append(load(path) as AudioStream)
	if _crackles.is_empty():
		return
	var distance := at.distance_to(eye)
	if distance > CRACKLE_FAR_M:
		return
	var h := WeatherHash.mix(int(bolt_seed * 100000.0), 11, 5, 2)
	var player := AudioStreamPlayer3D.new()
	Sfx3D.configure(player, _crackles[int(WeatherHash.unit(h) * _crackles.size()) % _crackles.size()], CRACKLE_DB,
			CRACKLE_NEAR_M, CRACKLE_FAR_M, Sfx3D.Attenuation.REALISTIC)
	player.pitch_scale = 1.0 + (WeatherHash.unit(WeatherHash.mix(h, 3, 0, 0)) * 2.0 - 1.0) * CRACKLE_PITCH
	player.attenuation_filter_cutoff_hz = lerpf(CRACKLE_CUTOFF_HZ.x, CRACKLE_CUTOFF_HZ.y,
			clampf(distance / CRACKLE_FAR_M, 0.0, 1.0))
	player.position = at
	player.finished.connect(player.queue_free)
	add_child(player)
	get_tree().create_timer(distance / SOUND_M_S).timeout.connect(func() -> void:
		if is_instance_valid(player):
			player.play())


## Strikes, flickers and puts out the sparks. [param wall]: the wall as the weather has it now;
## [param eye]: the eye, in this node's frame; [param under]: the ground under the wall, and
## [param bottom_m] the height of the box's bottom (both over the planet's reference sphere).
func advance(delta: float, wall: Dictionary, eye: Vector3, under: WallGround, bottom_m: float) -> void:
	_clock += delta
	var size := _box.transform.basis.get_scale()
	var frame := _box.transform.orthonormalized()
	var eye_m := frame.affine_inverse() * eye
	var may := float(wall["strength"]) >= MIN_STRENGTH and float(wall.get("spent", 0.0)) <= MAX_SPENT
	var flicker := _clock >= _flicker_at
	if flicker:
		_flicker_at = _clock + FLICKER_S
	for k in COUNT:
		var bolt := _bolts[k]
		if _clock >= _next[k] and may:
			_next[k] = _clock + randf_range(WAIT_S.x, WAIT_S.y)
			_until[k] = _clock + randf_range(LAST_S.x, LAST_S.y)
			_struck[k] = _clock
			var tall := randf_range(TALL_M.x, TALL_M.y)
			var x := clampf(eye_m.x + randf_range(-WINDOW_M, WINDOW_M), -size.x * 0.45, size.x * 0.45)
			var z := WeatherPhenomena.wall_front_m(x, size, float(wall["depth_m"])) - randf_range(BEHIND_M.x, BEHIND_M.y)
			var ground := under.height_at(frame * Vector3(x, 0.0, z)) - bottom_m - size.y * 0.5
			_where[k] = Vector3(x, ground + WeatherPhenomena.wall_tall(wall) * randf_range(FOOT.x, FOOT.y) + tall * 0.5, z)
			# Upright, turned to the eye.
			var at := frame * _where[k]
			var up := frame.basis.y
			var across := up.cross(eye - at).normalized()
			bolt.transform = Transform3D(Basis(across * tall * WIDE, up * tall, across.cross(up)), at)
			var bolt_seed := randf() * 10.0
			bolt.set_instance_shader_parameter("seed", bolt_seed)
			bolt.set_instance_shader_parameter("bolt_alt_m", bottom_m + size.y * 0.5 + _where[k].y)
			crackle(at, eye, bolt_seed)
			bolt.visible = true
			flicker = true
		var alight := _clock < _until[k]
		if not alight:
			bolt.visible = false
			_lit[k] = Vector4.ZERO
		else:
			if flicker:
				_bright[k] = randf_range(FLICKER.x, FLICKER.y)
				bolt.set_instance_shader_parameter("bright", _bright[k])
				bolt.set_instance_shader_parameter("open_air", open_air)
			var glow := _bright[k] * exp(-(_clock - _struck[k]) / GLOW_S)
			_lit[k] = Vector4(_where[k].x, _where[k].y, _where[k].z, glow)
	_material.set_shader_parameter("sparks", _lit)
