class_name VolcanoStoneField
extends Node3D
## The volcano's thrown stones, in two states:
##   - far from the player: an instance of ONE MultiMesh, flying on a closed-form arc in the shader. No
##     node, no CPU between birth and landing;
##   - landing near the player: promoted, just before impact, to a rock that takes over at the exact
##     position and velocity of the arc, then bounces, rolls and rests.
## The rocks are NOT physics bodies. A game client has no terrain collision at all (only the server has,
## in a frozen frame), so a RigidBody3D would fall through the ground. A rock integrates its own motion
## against the relief function (the same heights the terrain is built from), which also costs far less.
## A stone's whole flight is known at its birth, so the landing point is too: the promotion is a lookup,
## not a search. Like the smoke, every stone is a pure function of (time, slot): no state to replicate.

const COUNT := 4000
const PERIOD := 60.0
const GRAVITY := 9.81
## A stone landing closer than this to the player becomes a rock.
const PROMOTE_RADIUS_M := 350.0
## How long (s) before impact it does.
const PROMOTE_LEAD_S := 2.5
## Pebbles under this radius stay instances: nobody follows them rolling.
const PROMOTE_MIN_RADIUS_M := 0.2
const MAX_ROCKS := 160
## A resting rock stays this long (s), then sinks away. Sooner when the pool is full.
const ROCK_LIFE_S := 240.0
## Hard deadline even for rocks that never stop rolling; includes the ballistic flight.
const MAX_ROCK_AGE_S := 300.0
const DESPAWN_RADIUS_M := 750.0
const RETIRE_S := 3.0
const TRAIL_LIFE_S := 7.0
## Rest: slower than this (m/s) just after a bounce.
const REST_SPEED := 0.7
const BOUNCE := 0.3
const GRIP := 0.68
## Seconds for a rock to go from just-thrown to cold.
const COOL_S := 40.0
const BUCKET_S := 0.25
const MAX_DUST := 10
const ROCK_VARIANTS := 6
## One stone in this many leaves a smoke trail.
const TRAIL_STRIDE := 5
const TRAIL_SEGMENTS := 14
const SHADER_DIR := "res://assets/_universe/environment/terrain/volcano/"
## Height caches (m): a stone in flight only needs the rough ground, a rock on the ground the fine one.
const COARSE_CELL_M := 100.0
const FINE_CELL_M := 4.0
const MAX_HEIGHTS := 150000
## Heights a frame may read from the planet for new stones (each costs 0.15 to 0.3 ms). A stone over budget
## is born on a later frame, from the cells already read, so a single flight no longer makes a hitch.
const MAX_READS_PER_FRAME := 8
## A stone is never born later than this (s): it would appear too far from the vent. Later, it is not thrown.
const MAX_BIRTH_LAG_S := 1.0
## Main-thread time (us) a frame may spend reading heights for new stones. Reads slow down several times while
## the terrain streams (cold caches, workers busy): 8 reads then cost up to ~16 ms (2026-11-09, near a volcano).
const READ_BUDGET_USEC := 1500
const NO_READ_LIMIT := 1 << 30
const NO_DEADLINE := 1 << 62
static var _shared_meshes: Array[ArrayMesh] = []
static var _shared_flying_mesh: ArrayMesh
static var _shared_cracks: NoiseTexture3D

signal player_hit(impact_speed: float, radius: float)


## One landed rock.
class Rock:
	extends RefCounted
	var node: MeshInstance3D
	var p := Vector3.ZERO
	var v := Vector3.ZERO
	var r := 1.0
	var born := 0.0
	var axis := Vector3.UP
	var turn := 0.0
	var basis := Basis.IDENTITY
	var bounced := false
	var asleep := false
	var hit_player := false
	var rest_at := 0.0
	var heat_at := -INF
	var retire_at := -INF


var model: VolcanoPlumeModel
## relief(x, z) -> ground height in this node's frame.
var relief: Callable
var mat := ShaderMaterial.new()
var trail_mat := ShaderMaterial.new()
var rock_mat := ShaderMaterial.new()
## Launch speed and share of the slots used, for a volcano smaller than the reference one.
var speed_scale := 1.0
var throw_rate := 1.0
## False in the game: a slot is only ever filled from now on, never all at once (each costs height samples).
var rebuild_on_jump := true
var promoted_total := 0
var flying := 0
var _flying_at := -INF

var _img: Image
var _tex: ImageTexture
var _dirty := false
var _next_c := 0
var _last_t := -INF
var _token := PackedInt32Array()
var _land_t := PackedFloat64Array()
var _birth := PackedFloat64Array()
var _v0 := PackedVector3Array()
var _radius := PackedFloat32Array()
var _buckets := {}
var _next_bucket := 0
var _rocks: Array[Rock] = []
var _rock_meshes: Array[ArrayMesh] = []
var _dust_mat: StandardMaterial3D
var _dust_nodes: Array[CPUParticles3D] = []
var _eye := Vector3.ZERO
var _feet := Vector3.ZERO
var _has_player := false
var _heights := {}
var _reads_left := NO_READ_LIMIT
var _read_deadline := NO_DEADLINE
var _latest_landing := -INF
var _latest_trail_end := -INF
var _suspended := false
var _stepping := false
var _instances: MultiMeshInstance3D
var _trails: MultiMeshInstance3D


func _init(plume: VolcanoPlumeModel, relief_height: Callable) -> void:
	model = plume
	relief = relief_height
	_token.resize(COUNT)
	_land_t.resize(COUNT)
	_birth.resize(COUNT)
	_v0.resize(COUNT)
	_radius.resize(COUNT)
	_img = Image.create_empty(COUNT, 2, false, Image.FORMAT_RGBAF)
	_tex = ImageTexture.create_from_image(_img)
	var cracks := _make_crack_texture()
	mat.shader = load(SHADER_DIR + "stones.gdshader")
	mat.set_shader_parameter("stone_tex", _tex)
	mat.set_shader_parameter("crack_tex", cracks)
	mat.set_shader_parameter("period", PERIOD)
	mat.set_shader_parameter("gravity", GRAVITY)
	rock_mat.shader = load(SHADER_DIR + "rock.gdshader")
	rock_mat.set_shader_parameter("crack_tex", cracks)
	if _shared_meshes.is_empty():
		for variant in ROCK_VARIANTS:
			_shared_meshes.append(make_rock(28, 14, variant))
		_shared_flying_mesh = make_rock(9, 5, 99)
	_rock_meshes = _shared_meshes
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _shared_flying_mesh
	mm.instance_count = COUNT
	# The real position is computed in the shader: all the instances sit at the origin.
	for i in COUNT:
		mm.set_instance_transform(i, Transform3D.IDENTITY)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Stones"
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.custom_aabb = AABB(Vector3(-20000, -6000, -20000), Vector3(40000, 26000, 40000))
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	_instances = mmi
	_instances.hide()
	_build_trails()
	_trails.hide()
	_dust_mat = StandardMaterial3D.new()
	_dust_mat.albedo_color = Color(0.3, 0.28, 0.26, 0.5)
	_dust_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_dust_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	_dust_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_dust_mat.vertex_color_use_as_albedo = true
	var blob := GradientTexture2D.new()
	blob.fill = GradientTexture2D.FILL_RADIAL
	blob.fill_from = Vector2(0.5, 0.5)
	blob.fill_to = Vector2(1.0, 0.5)
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 1))
	ramp.set_color(1, Color(1, 1, 1, 0))
	blob.gradient = ramp
	_dust_mat.albedo_texture = blob
	set_physics_process(false)


## Called when distance/visibility budgets stop updating this field. Hidden rocks must not
## continue physics against stale camera/time data or retain their terrain cache forever.
func suspend() -> void:
	if _suspended:
		return
	_suspended = true
	_reset_transients()
	_heights.clear()
	_last_t = -INF


func _reset_transients() -> void:
	for rock in _rocks:
		_remove_node(rock.node)
	_rocks.clear()
	for puff in _dust_nodes:
		_remove_node(puff)
	_dust_nodes.clear()
	_buckets.clear()
	_land_t.fill(-1.0)
	_radius.fill(0.0)
	_img.fill(Color.TRANSPARENT)
	_tex.update(_img)
	_dirty = false
	flying = 0
	_flying_at = -INF
	_latest_landing = -INF
	_latest_trail_end = -INF
	_has_player = false
	_instances.hide()
	_trails.hide()
	set_physics_process(false)


static func _remove_node(node: Node3D) -> void:
	node.hide()
	node.queue_free()


static func _make_crack_texture() -> NoiseTexture3D:
	if _shared_cracks != null:
		return _shared_cracks
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
	noise.frequency = 0.09
	noise.fractal_type = FastNoiseLite.FRACTAL_NONE
	var tex := NoiseTexture3D.new()
	tex.width = 64
	tex.height = 64
	tex.depth = 64
	tex.seamless = true
	tex.normalize = true
	tex.noise = noise
	_shared_cracks = tex
	return tex


## A broken block of radius about 1: a ball cut by a few planes, so it has faces and edges rather than
## the look of a dented sphere. Deterministic from [param variant].
static func make_rock(radial: int, rings: int, variant: int) -> ArrayMesh:
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = radial
	sphere.rings = rings
	var arrays := sphere.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var cuts: Array[Vector4] = []
	for k in 9:
		var a := TAU * VolcanoPlumeModel._hash(variant * 31 + k, 201)
		var y := VolcanoPlumeModel._hash(variant * 31 + k, 202) * 2.0 - 1.0
		var flat := sqrt(maxf(1.0 - y * y, 0.0))
		cuts.append(Vector4(cos(a) * flat, y, sin(a) * flat, lerpf(0.5, 0.92, VolcanoPlumeModel._hash(variant * 31 + k, 203))))
	var stretch := Vector3(
		lerpf(0.8, 1.2, VolcanoPlumeModel._hash(variant, 204)),
		lerpf(0.65, 1.05, VolcanoPlumeModel._hash(variant, 205)),
		lerpf(0.85, 1.25, VolcanoPlumeModel._hash(variant, 206))
	)
	var noise := FastNoiseLite.new()
	noise.seed = variant + 7
	noise.frequency = 0.9
	noise.fractal_octaves = 3
	for i in verts.size():
		var p := verts[i]
		for c in cuts:
			var over := p.x * c.x + p.y * c.y + p.z * c.z - c.w
			if over > 0.0:
				p -= Vector3(c.x, c.y, c.z) * over
		p *= 1.0 + 0.09 * noise.get_noise_3dv(p * 2.0)
		verts[i] = p * stretch
	arrays[Mesh.ARRAY_VERTEX] = verts
	var st := SurfaceTool.new()
	st.create_from_arrays(arrays)
	st.generate_normals()
	return st.commit()


## From gravel to a house-sized block, the small ones by far the most common.
static func stone_radius(u: float, v: float) -> float:
	if u < 0.62:
		return lerpf(0.08, 0.3, v)
	if u < 0.9:
		return lerpf(0.3, 0.9, v)
	if u < 0.985:
		return lerpf(0.9, 2.0, v)
	return lerpf(2.0, 4.5, v)


## [param eye]: the camera, for promotions. [param feet]: the player's, when there is one on the ground.
func update(t: float, eye: Vector3, feet: Vector3, has_player: bool) -> void:
	_suspended = false
	_eye = eye
	mat.set_shader_parameter("t_mod", fmod(t, PERIOD))
	trail_mat.set_shader_parameter("t_mod", fmod(t, PERIOD))
	trail_mat.set_shader_parameter("cam_local", eye)
	mat.set_shader_parameter("cam_local", eye)
	var dt := PERIOD / float(COUNT)
	if absf(t - _last_t) > 5.0:
		_rebuild(t)
	_last_t = t
	_feet = feet
	_has_player = has_player
	_reads_left = MAX_READS_PER_FRAME
	_read_deadline = Time.get_ticks_usec() + READ_BUDGET_USEC
	while float(_next_c) * dt <= t:
		if t - float(_next_c) * dt > MAX_BIRTH_LAG_S:
			# Too late to leave the vent: not thrown. Reading all its heights now made the long frames longer.
			_skip(_next_c)
		elif not _born(_next_c, t):
			break
		_next_c += 1
	_read_deadline = NO_DEADLINE
	_promote_due(t, eye)
	_instances.visible = t < _latest_landing
	_trails.visible = t < _latest_trail_end
	set_physics_process(not _rocks.is_empty())
	if _dirty:
		_tex.update(_img)
		_dirty = false


## A jump in time: every slot is what it would have been by now.
func _rebuild(t: float) -> void:
	_reset_transients()
	var dt := PERIOD / float(COUNT)
	_buckets.clear()
	_next_bucket = floori(t / BUCKET_S)
	_next_c = floori(t / dt) + 1
	if not rebuild_on_jump:
		return
	_reads_left = NO_READ_LIMIT
	for c in range(_next_c - COUNT, _next_c):
		_born(c, t)


## False when the frame's height reads ran out: nothing changed, to call again on a later frame.
func _born(c: int, t: float) -> bool:
	var i := posmod(c, COUNT)
	var birth := float(c) * (PERIOD / float(COUNT))
	# The volcano throws in bursts: stones only when it is strong, and each burst leans its own way.
	var strength := model.eruption_activity(birth)
	if strength <= 0.0 or VolcanoPlumeModel._hash(c, 101) >= smoothstep(0.55, 1.1, strength) * throw_rate:
		_token[i] += 1
		_clear_slot(i, birth)
		return true
	var r1 := VolcanoPlumeModel._hash(c, 102)
	var r2 := VolcanoPlumeModel._hash(c, 103)
	var r3 := VolcanoPlumeModel._hash(c, 104)
	var seed_v := VolcanoPlumeModel._hash(c, 106)
	var burst := floori(birth / 3.0)
	var lean := Vector2(VolcanoPlumeModel._hash(burst, 107) - 0.5, VolcanoPlumeModel._hash(burst, 108) - 0.5) * 0.5
	var radius := stone_radius(VolcanoPlumeModel._hash(c, 105), VolcanoPlumeModel._hash(c, 109))
	# A big block leaves slower than gravel.
	var speed := (
		lerpf(55.0, 235.0, r1 * r1) * lerpf(1.0, 0.55, clampf(radius / 4.5, 0.0, 1.0)) * speed_scale * sqrt(clampf(strength, 0.1, 4.0))
	)
	var ang := TAU * r2
	var tilt := sqrt(r3) * 0.55
	var dir := Vector3(cos(ang) * tilt + lean.x, 1.0, sin(ang) * tilt + lean.y).normalized()
	var v0 := dir * speed
	var flight := _flight_time(v0)
	if flight < 0.0:
		return false
	_token[i] += 1
	_write(i, v0, birth, radius, flight, seed_v, 1.0)
	_register(i, v0, birth, radius, flight, t)
	return true


## Slot [param c] throws nothing: its previous flight, if any, is cleared like an idle slot's.
func _skip(c: int) -> void:
	var i := posmod(c, COUNT)
	_token[i] += 1
	_clear_slot(i, float(c) * (PERIOD / float(COUNT)))


## First time the arc from the vent reaches the ground, or -1 when the frame's height reads ran out: the
## cells read so far stay cached, and the same call goes further next time to the same result. Long strides,
## then a short search: in the game every sample reads the planet's height function.
func _flight_time(v0: Vector3) -> float:
	var ft := 3.0
	while ft < PERIOD - 10.0:
		if _reads_left <= 0:
			return -1.0
		var p := _arc(v0, ft)
		if p.y <= _ground(p.x, p.z, COARSE_CELL_M):
			break
		ft += 1.5
	var lo := ft - 1.5
	var hi := ft
	for _k in 6:
		if _reads_left <= 0:
			return -1.0
		var mid := 0.5 * (lo + hi)
		var p := _arc(v0, mid)
		if p.y <= _ground(p.x, p.z, COARSE_CELL_M):
			hi = mid
		else:
			lo = mid
	return minf(hi, PERIOD - 10.0)


static func _arc(v0: Vector3, age: float) -> Vector3:
	return v0 * age + Vector3(0.0, -0.5 * GRAVITY * age * age, 0.0)


func _write(i: int, v0: Vector3, birth: float, radius: float, flight: float, seed_v: float, shown: float) -> void:
	_img.set_pixel(i, 0, Color(v0.x, v0.y, v0.z, fmod(birth, PERIOD)))
	_img.set_pixel(i, 1, Color(radius, flight, seed_v, shown))
	_dirty = true


func _register(i: int, v0: Vector3, birth: float, radius: float, flight: float, t: float) -> void:
	_birth[i] = birth
	_v0[i] = v0
	_radius[i] = radius
	_land_t[i] = birth + flight
	_latest_landing = maxf(_latest_landing, _land_t[i])
	_latest_trail_end = maxf(_latest_trail_end, _land_t[i] + TRAIL_LIFE_S)
	if _land_t[i] > t:
		var key := floori((_land_t[i] - PROMOTE_LEAD_S) / BUCKET_S)
		_schedule_slot_event(key, [i, _token[i]])
	if _land_t[i] + TRAIL_LIFE_S > t:
		# Clear before the shader's modulo clock can repeat an old flight. Birth is the
		# flight identity: promotion changes its token but must not cancel its expiration.
		var expiry := ceili((_land_t[i] + TRAIL_LIFE_S) / BUCKET_S)
		_schedule_slot_event(expiry, [i, birth, true])


func _schedule_slot_event(key: int, event: Array) -> void:
	key = maxi(key, _next_bucket)
	if not _buckets.has(key):
		_buckets[key] = []
	(_buckets[key] as Array).append(event)


func _clear_slot(i: int, t: float) -> void:
	if _radius[i] > 0.0:
		_write(i, Vector3.ZERO, t, 0.0, 0.0, 0.0, 0.0)
		_radius[i] = 0.0
	_land_t[i] = -1.0


## Test volley: [param n] stones aimed around [param target], landing in a few seconds.
func volley_at(target: Vector3, n: int, t: float, spread_m: float = 220.0) -> void:
	for k in n:
		var i := posmod(_next_c - 1 - k, COUNT)
		_token[i] += 1
		var a := randf() * TAU
		var d := sqrt(randf()) * spread_m
		var x := target.x + cos(a) * d
		var z := target.z + sin(a) * d
		var y: float = relief.call(x, z)
		# A natural arc from the vent, leaving at 65 degrees, and already in the air: it arrives in a few
		# seconds at a believable speed. Rushing the whole flight into those seconds made 300 m/s stones.
		var flat := sqrt(x * x + z * z)
		var flight := minf(sqrt(maxf(2.0 * (flat * tan(deg_to_rad(65.0)) - y) / GRAVITY, 1.0)), PERIOD - 12.0)
		var v0 := Vector3(x / flight, (y + 0.5 * GRAVITY * flight * flight) / flight, z / flight)
		var remaining := minf(randf_range(6.0, 11.0), flight)
		var birth := t - (flight - remaining)
		var radius := maxf(stone_radius(randf(), randf()), PROMOTE_MIN_RADIUS_M)
		_write(i, v0, birth, radius, flight, randf(), 1.0)
		_register(i, v0, birth, radius, flight, t)


func _promote_due(t: float, eye: Vector3) -> void:
	var now := floori(t / BUCKET_S)
	while _next_bucket <= now:
		var due: Array = _buckets.get(_next_bucket, [])
		_buckets.erase(_next_bucket)
		_next_bucket += 1
		for entry: Array in due:
			var i: int = entry[0]
			if entry.size() == 3:
				if entry[1] == _birth[i]:
					_clear_slot(i, t)
				continue
			if entry[1] != _token[i] or t >= _land_t[i] - 0.05 or _radius[i] < PROMOTE_MIN_RADIUS_M:
				continue
			var age := t - _birth[i]
			var land := _arc(_v0[i], _land_t[i] - _birth[i])
			if land.distance_to(eye) <= PROMOTE_RADIUS_M:
				_promote(i, t, _arc(_v0[i], age), _v0[i] + Vector3(0.0, -GRAVITY * age, 0.0), age)


func _promote(i: int, t: float, p: Vector3, v: Vector3, age: float) -> void:
	# Out of the MultiMesh in the same frame the rock appears.
	var row := _img.get_pixel(i, 1)
	row.a = 2.0  # no more instance, but its trail goes on
	_img.set_pixel(i, 1, row)
	_dirty = true
	_token[i] += 1
	promoted_total += 1
	_spawn_rock(t - age, p, v, _radius[i], i)


func _spawn_rock(born: float, p: Vector3, v: Vector3, r: float, variety: int) -> void:
	if _rocks.size() >= MAX_ROCKS and (_stepping or not _evict_one()):
		return
	var rock := Rock.new()
	rock.p = p
	rock.v = v
	rock.r = r
	rock.born = born
	rock.axis = (
		Vector3(
			VolcanoPlumeModel._hash(variety, 301) - 0.5,
			VolcanoPlumeModel._hash(variety, 302) - 0.5,
			VolcanoPlumeModel._hash(variety, 303) - 0.5
		)
		. normalized()
	)
	rock.turn = (VolcanoPlumeModel._hash(variety, 304) - 0.5) * 5.0
	rock.basis = Basis(rock.axis, TAU * VolcanoPlumeModel._hash(variety, 305))
	var node := MeshInstance3D.new()
	node.mesh = _rock_meshes[posmod(variety, ROCK_VARIANTS)]
	node.material_override = rock_mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if r > 0.25 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	node.set_instance_shader_parameter(&"rock_seed", VolcanoPlumeModel._hash(variety, 306) * 37.0)
	node.set_instance_shader_parameter(&"rock_radius", r)
	rock.node = node
	_place(rock)
	_rocks.append(rock)
	set_physics_process(true)


func _place(rock: Rock) -> void:
	rock.node.transform = Transform3D(rock.basis.scaled_local(Vector3.ONE * rock.r), rock.p)


## The oldest resting rock leaves to make room: never one still in the air.
func _evict_one() -> bool:
	for k in _rocks.size():
		if _rocks[k].asleep or _rocks[k].retire_at != -INF:
			_remove_node(_rocks[k].node)
			_rocks.remove_at(k)
			return true
	return false


func _physics_process(delta: float) -> void:
	_stepping = true
	var k := 0
	# New shards start next tick; one impact cannot recursively spend the whole frame.
	var existing := _rocks.size()
	while k < existing:
		var rock := _rocks[k]
		if rock.retire_at != -INF:
			var progress := clampf((_last_t - rock.retire_at) / RETIRE_S, 0.0, 1.0)
			if progress >= 1.0:
				_remove_node(rock.node)
				_rocks.remove_at(k)
				existing -= 1
				continue
			rock.node.scale = Vector3.ONE * rock.r * (1.0 - smoothstep(0.0, 1.0, progress))
			k += 1
			continue
		if _last_t - rock.born >= MAX_ROCK_AGE_S or rock.p.distance_squared_to(_eye) > DESPAWN_RADIUS_M * DESPAWN_RADIUS_M:
			_retire(rock)
			k += 1
			continue
		if rock.asleep:
			if _last_t - rock.rest_at > ROCK_LIFE_S:
				_retire(rock)
				k += 1
				continue
		else:
			_step(rock, delta)
		if _last_t - rock.heat_at > 0.5:
			rock.heat_at = _last_t
			rock.node.set_instance_shader_parameter(&"heat", clampf(1.0 - (_last_t - rock.born) / COOL_S, 0.0, 1.0))
		k += 1
	_stepping = false
	if _rocks.is_empty():
		set_physics_process(false)


func _step(rock: Rock, delta: float) -> void:
	var before := rock.p
	rock.v.y -= GRAVITY * delta
	rock.p += rock.v * delta
	rock.basis = rock.basis.rotated(rock.axis, rock.turn * delta)
	if _has_player and not rock.hit_player and rock.v.length_squared() > 400.0:
		# The stone's whole step against the player's body: a fast stone cannot pass through unseen.
		var chest := _feet + Vector3.UP * 0.9
		var nearest := Geometry3D.get_closest_point_to_segment(chest, before, rock.p)
		if nearest.distance_to(chest) < rock.r * 0.9 + 0.9:
			rock.hit_player = true
			player_hit.emit(rock.v.length(), rock.r)
	if rock.p.y > _ground(rock.p.x, rock.p.z, COARSE_CELL_M) + 80.0:
		_place(rock)
		return
	var ground := _ground(rock.p.x, rock.p.z, FINE_CELL_M)
	var clearance := rock.r * 0.8
	if rock.p.y >= ground + clearance:
		_place(rock)
		return
	# The slope under the rock, sampled at its own size.
	var s := maxf(rock.r, FINE_CELL_M)
	var dx := _ground(rock.p.x + s, rock.p.z, FINE_CELL_M)
	var dz := _ground(rock.p.x, rock.p.z + s, FINE_CELL_M)
	var n := Vector3(ground - dx, s, ground - dz).normalized()
	rock.p.y = ground + clearance
	var into := rock.v.dot(n)
	if into < 0.0:
		var impact := -into
		if not rock.bounced:
			rock.bounced = true
			_impact(rock, impact)
		var along := rock.v - n * into
		# Rolls: the spin follows the ground speed.
		if along.length() > 0.1:
			rock.axis = n.cross(along.normalized()).normalized()
			rock.turn = along.length() / maxf(rock.r, 0.1)
		rock.v = along * GRIP + n * (impact * BOUNCE)
		if rock.v.length() < REST_SPEED and impact < 3.0:
			rock.asleep = true
			rock.rest_at = _last_t
			rock.v = Vector3.ZERO
	_place(rock)


func _impact(rock: Rock, impact: float) -> void:
	if _dust_nodes.size() < MAX_DUST:
		_dust(rock.p, rock.r, impact)
	# A block breaks on landing: the chaos of a few small hot shards.
	if rock.r > 0.6 and impact > 15.0:
		var shards := mini(int(rock.r * 4.0) + 2, 8)
		for j in shards:
			var a := TAU * randf()
			var kick := Vector3(cos(a), randf_range(0.4, 1.2), sin(a)) * impact * randf_range(0.12, 0.32)
			_spawn_rock(rock.born, rock.p + kick.normalized() * rock.r, kick, rock.r * randf_range(0.08, 0.26), randi())


func _dust(at: Vector3, r: float, impact: float) -> void:
	if _dust_nodes.size() >= MAX_DUST:
		return
	var puff := CPUParticles3D.new()
	_dust_nodes.append(puff)
	puff.one_shot = true
	puff.explosiveness = 0.9
	puff.amount = 8 + mini(int(r * 8.0), 22)
	puff.lifetime = 3.0 + r
	puff.local_coords = true
	puff.direction = Vector3.UP
	puff.spread = 65.0
	puff.initial_velocity_min = 1.0
	puff.initial_velocity_max = minf(impact * 0.18, 26.0) + r * 3.0
	puff.gravity = Vector3(0.0, -1.2, 0.0)
	puff.damping_min = 1.5
	puff.damping_max = 3.5
	puff.scale_amount_min = 0.8 + r * 1.2
	puff.scale_amount_max = 2.0 + r * 3.5
	var fade := Gradient.new()
	fade.set_color(0, Color(0.34, 0.31, 0.28, 0.55))
	fade.set_color(1, Color(0.3, 0.28, 0.26, 0.0))
	puff.color_ramp = fade
	var quad := QuadMesh.new()
	quad.material = _dust_mat
	puff.mesh = quad
	add_child(puff)
	puff.position = at
	puff.emitting = true
	puff.finished.connect(
		func() -> void:
			_dust_nodes.erase(puff)
			puff.queue_free()
	)


func _retire(rock: Rock) -> void:
	# Keep the fading node in the same capped pool: no untracked Tween/node backlog.
	if rock.retire_at == -INF:
		rock.retire_at = _last_t


func props_alive() -> int:
	return _rocks.size()


func rocks_at_rest() -> int:
	var n := 0
	for rock in _rocks:
		if rock.asleep:
			n += 1
	return n


func has_live_stones(t: float) -> bool:
	return t < _latest_landing or not _rocks.is_empty()


func in_flight(t: float) -> int:
	if t >= _latest_landing:
		return 0
	if absf(t - _flying_at) < 0.25:
		return flying
	_flying_at = t
	var n := 0
	for i in COUNT:
		if _land_t[i] > t:
			n += 1
	flying = n
	return n


## One ribbon per TRAIL_STRIDE-th slot. UV.x runs from the stone back along the trail, UV.y across it.
func _build_trails() -> void:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for s in TRAIL_SEGMENTS + 1:
		var u := float(s) / float(TRAIL_SEGMENTS)
		verts.append(Vector3(-1.0, 0.0, 0.0))
		verts.append(Vector3(1.0, 0.0, 0.0))
		uvs.append(Vector2(u, 0.0))
		uvs.append(Vector2(u, 1.0))
	for s in TRAIL_SEGMENTS:
		var i := s * 2
		idx.append_array([i, i + 1, i + 2, i + 1, i + 3, i + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var strip := ArrayMesh.new()
	strip.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	trail_mat.shader = load(SHADER_DIR + "trails.gdshader")
	trail_mat.set_shader_parameter("stone_tex", _tex)
	trail_mat.set_shader_parameter("period", PERIOD)
	trail_mat.set_shader_parameter("gravity", GRAVITY)
	trail_mat.set_shader_parameter("stride", TRAIL_STRIDE)
	trail_mat.set_shader_parameter("trail_s", TRAIL_LIFE_S)
	trail_mat.set_shader_parameter("wind", Vector3(model.wind.x, 0.0, model.wind.y) * 0.25)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = strip
	mm.instance_count = COUNT / TRAIL_STRIDE
	for i in mm.instance_count:
		mm.set_instance_transform(i, Transform3D.IDENTITY)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Trails"
	mmi.multimesh = mm
	mmi.material_override = trail_mat
	mmi.custom_aabb = AABB(Vector3(-20000, -6000, -20000), Vector3(40000, 26000, 40000))
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	_trails = mmi


## The ground at (x, z), from a cache of cells [param cell] metres wide: in the game one reading of the
## planet's height function costs far too much (170 us measured) to make per stone and per frame.
func _ground(x: float, z: float, cell: float) -> float:
	var fx := x / cell
	var fz := z / cell
	var ix := floori(fx)
	var iz := floori(fz)
	var u := fx - float(ix)
	var w := fz - float(iz)
	return lerpf(
		lerpf(_height_at(ix, iz, cell), _height_at(ix + 1, iz, cell), u),
		lerpf(_height_at(ix, iz + 1, cell), _height_at(ix + 1, iz + 1, cell), u),
		w
	)


func _height_at(ix: int, iz: int, cell: float) -> float:
	var key := Vector3i(ix, iz, int(cell))
	if _heights.has(key):
		return _heights[key]
	if _heights.size() >= MAX_HEIGHTS:
		_heights.clear()
	var h: float = relief.call(float(ix) * cell, float(iz) * cell)
	_reads_left -= 1
	if Time.get_ticks_usec() > _read_deadline:
		_reads_left = 0  # the frame's time for reads is spent, whatever their count
	_heights[key] = h
	return h
