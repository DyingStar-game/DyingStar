@tool
class_name Planet
extends Node3D

signal hs_server_prop_move

@export_tool_button("update") var on_update = update_planet

@export var planet_settings: PlanetSettings

@export var uuid: String = ""

# ──────────────────────────────────────────────────────────────
#  Paramètres d’orbite (valeurs par défaut sûres)
# ──────────────────────────────────────────────────────────────
@export var orbit_enabled: bool = true
@export var align_orbit_to_spawn: bool = true      # aligne M0 pour passer par la position initiale
@export var star_mass_kg: float = 1.98847e30       # ~ Soleil pour éviter n=0
@export var planet_mass_kg: float = 5.972e24       # ~ Terre
@export var periapsis_AU: float = 0.0              # si 0 ET apo=0 => on déduit a depuis le spawn
@export var apoapsis_AU: float = 0.0
@export var inc_deg: float = 0.0
@export var node_deg: float = 0.0                  # Ω
@export var arg_peri_deg: float = 0.0              # ω
@export var mean_anomaly_deg: float = 0.0          # M0 
@export var time_scale: float = 1.0            # 1s écran = 1 jour si delta=1s
@export var debug_fast_orbit: bool = true
@export var debug_multiplier: float = 0.001      # x1000 sur la vitesse d’orbite pour tester
@export var enable_spin_motion: bool = false   # rotation visuelle de la planète
@export var spin_speed_base: float = 0.001     # vitesse de spin (rad/s environ)
# ligne d'orbite
@export var orbit_line_enabled: bool = true
@export var orbit_line_segments: int = 384      # résolution de l’ellipse
@export var orbit_line_color: Color = Color(1,1,1,0.18)
@export var orbit_line_as_ribbon: bool = false  # false: simple LINE_STRIP, true: fin ruban
@export var orbit_line_ribbon_width_m: float = 2.0e7  # demi-largeur du ruban en mètres (si ribbon)
# ───────── Beacon (repère vertical) ─────────
@export var beacon_enabled: bool = false:
	set(value):
		beacon_enabled = value
		if is_inside_tree():
			_rebuild_beacon()
@export var beacon_attach_to_planet: bool = true   
@export var beacon_auto_height: bool = true        # calcule H depuis rayon planète
@export var beacon_extra_km: float = 5000000.0       # dépassement au-dessus/bas 
@export var beacon_height_m: float = 1.0e8         # utilisé si auto=false 
@export var beacon_thickness_m: float = 1.0e6      
@export var beacon_color: Color = Color(0, 1, 0, 0.9)
@export var beacon_emission: float = 3.0


var _beacon_node: MeshInstance3D = null

var _orbit_line_node: MeshInstance3D = null     # nœud qui porte le mesh de la ligne

# ──────────────────────────────────────────────────────────────
#  Constantes et état interne
# ──────────────────────────────────────────────────────────────
const AU_M: float = 1.495978707e11
const G: float = 6.67430e-11

var _a_m: float = 0.0            # demi-grand axe (m)
var _e: float = 0.0              # excentricité
var _n: float = 0.0              # vitesse moyenne (rad/s)
var _M: float = 0.0              # anomalie moyenne courante (rad)
var _basis := Basis()            # base orbitale Rz(Ω)*Rx(i)*Rz(ω)
var _orbit_center := Vector3.ZERO
# var _dbg_t: float = 0.0


var spawn_position: Vector3 = Vector3.ZERO

@onready var planet_gravity: PhysicsGrid = $PlanetTerrain/PlanetGravity
@onready var planet_terrain: PlanetTerrain = $PlanetTerrain
@onready var atmosphere: ExtremelyFastAtmpsphere = $Atmosphere
@onready var water_surface: MeshInstance3D = $WaterSurface

func _enter_tree() -> void:
	if Engine.is_editor_hint(): return
	global_position = spawn_position
	if not OS.has_feature("dedicated_server"):
		$Atmosphere.sun_object = get_tree().current_scene.get_node("Star/DirectionalLight3D")


func _ready() -> void:
	set_process(true)
	if orbit_enabled:
		_setup_orbit()
		if align_orbit_to_spawn:
			_anchor_orbit_to_current_position()
	update_planet()  
	if orbit_line_enabled:
		_rebuild_orbit_line()
	if beacon_enabled:
		_rebuild_beacon()

func _process(delta: float) -> void:
	if Engine.is_editor_hint(): return

	if not orbit_enabled:
		return
	if beacon_enabled and _beacon_node and not beacon_attach_to_planet:
		
		_beacon_node.global_position = global_position
	var speed_mult := (debug_multiplier if debug_fast_orbit else 1.0)
	
	if GameOrchestrator.is_server():
		_M = fmod(_M + _n * time_scale * delta * speed_mult, TAU)
		
		var pos_plane = _kepler_position(_a_m, _e, _M)
		global_position = _orbit_center + (_basis * pos_plane)

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint(): return
	# spin visuel seulement
	if enable_spin_motion:
		planet_terrain.rotation.y += spin_speed_base * delta

	if GameOrchestrator.is_server():
		emit_signal("hs_server_prop_move", uuid, global_position, global_rotation, "planet")


# func update_planet():
# 	planet_gravity.gravity_point_unit_distance = planet_settings.radius
# 	var shape = planet_gravity.get_node("CollisionShape3D").shape as SphereShape3D
# 	shape.radius = planet_settings.radius + planet_settings.atmosphere_height

# 	planet_terrain.radius = planet_settings.radius
# 	planet_terrain.terrain_material = planet_settings.terrain_material
# 	planet_terrain.terrain_settings = planet_settings.terrain_settings

# 	atmosphere.atmosphere_height = planet_settings.atmosphere_height
# 	atmosphere.planet_radius = planet_settings.radius + 600

# 	if planet_settings.has_ocean:
# 		var watermesh = water_surface.mesh as SphereMesh
# 		watermesh.radius = planet_settings.radius + planet_settings.sea_level
# 		watermesh.height = (planet_settings.radius + planet_settings.sea_level) * 2
# 		water_surface.show()
# 	else:
# 		water_surface.hide()

# 	planet_terrain.trigger_update()

# ──────────────────────────────────────────────────────────────
#  Montage de l’orbite
# ──────────────────────────────────────────────────────────────
func _setup_orbit() -> void:
	# centre d’orbite = l’étoile au (0,0,0) pour l’instant
	_orbit_center = Vector3.ZERO
	_orbit_center = Vector3(global_position[0] - 8999498785.9, 0.0, 0.0)

	# demi-grand axe & excentricité
	if periapsis_AU > 0.0 or apoapsis_AU > 0.0:
		var rp_AU := (periapsis_AU if periapsis_AU > 0.0 else apoapsis_AU)
		var ra_AU := (apoapsis_AU  if apoapsis_AU  > 0.0 else periapsis_AU)
		if ra_AU < rp_AU:
			var tmp := ra_AU
			ra_AU = rp_AU
			rp_AU = tmp
		_a_m = 0.5 * (rp_AU + ra_AU) * AU_M
		_e = max(0.0, (ra_AU - rp_AU) / max(ra_AU + rp_AU, 1e-12))
	else:
		
		var d_m := global_position.distance_to(_orbit_center)
		_a_m = max(d_m, 1.0)   # évite a=0
		_e = 0.0               # orbite circulaire par défaut

	# base orbitale (orientation du plan)
	_basis = _orbit_basis(arg_peri_deg, inc_deg, node_deg)

	# paramètres dynamiques : μ, n, M0
	var mu = G * max(star_mass_kg + planet_mass_kg, 1.0)  # μ>0
	_n = sqrt(mu / pow(_a_m, 3.0))
	_M = deg_to_rad(mean_anomaly_deg)

func _anchor_orbit_to_current_position() -> void:

	var rel := _basis.inverse() * (global_position - _orbit_center)
	var x := rel.x
	var z := rel.z

	# Résoudre E à partir de:
	#  x = a (cosE - e)
	#  z = a sqrt(1-e^2) sinE
	var a := _a_m
	var c = clamp((_safe_div(x, a)) + _e, -1.0, 1.0)
	var s := _safe_div(z, a * sqrt(max(1.0 - _e * _e, 1e-12)))
	var E := atan2(s, c)
	_M = E - _e * sin(E)


func _update_orbit_position(dt: float) -> void:
	_M = fmod(_M + _n * dt, TAU)
	var E: float = _kepler_E_from_M(_M, _e)
	var xp: float = _a_m * (cos(E) - _e)
	var zp: float = _a_m * (sqrt(1.0 - _e * _e) * sin(E))
	var pos_plane: Vector3 = Vector3(xp, 0.0, zp)
	global_position = _basis * pos_plane + _orbit_center

# -------------------------------------------------------
# Kepler helpers
# -------------------------------------------------------
static func _normalize_angle_rad(a: float) -> float:
	var x := fmod(a, TAU)
	if x < 0.0: x += TAU
	return x

# -------------------------------------------------------
# Visuel / terrain (inchangé)
# -------------------------------------------------------
func update_planet():
	planet_gravity.gravity_point_unit_distance = planet_settings.radius
	var shape = planet_gravity.get_node("CollisionShape3D").shape as SphereShape3D
	shape.radius = planet_settings.radius + planet_settings.atmosphere_height

	planet_terrain.radius = planet_settings.radius
	planet_terrain.terrain_material = planet_settings.terrain_material
	planet_terrain.terrain_settings = planet_settings.terrain_settings

	atmosphere.atmosphere_height = planet_settings.atmosphere_height
	atmosphere.planet_radius = planet_settings.radius + 600

	if planet_settings.has_ocean:
		var watermesh = water_surface.mesh as SphereMesh
		watermesh.radius = planet_settings.radius + planet_settings.sea_level
		watermesh.height = (planet_settings.radius + planet_settings.sea_level) * 2
		water_surface.show()
	else:
		water_surface.hide()

	planet_terrain.trigger_update()

# ──────────────────────────────────────────────────────────────
#  Utilitaires orbite (versions locales)
# ──────────────────────────────────────────────────────────────
func _kepler_position(a_m: float, e: float, M: float) -> Vector3:
	var ee := _clamp_e(e)
	var E := _kepler_E_from_M(M, ee)
	var xp := a_m * (cos(E) - ee)
	var zp := a_m * (sqrt(max(1.0 - ee * ee, 0.0)) * sin(E))
	return Vector3(xp, 0.0, zp)

func _kepler_E_from_M(M: float, e: float) -> float:
	var Mm := _norm(M)
	var E := (PI if e > 0.8 else Mm)
	for _i in range(8):
		var f := E - e * sin(E) - Mm
		var fp := 1.0 - e * cos(E)
		var step = -f / max(fp, 1e-12)
		E += step
		if abs(step) < 1e-12:
			break
	return _norm(E)

func _orbit_basis(arg_peri_deg: float, inc_deg: float, node_deg: float) -> Basis:
	var b := Basis()
	b = b.rotated(Vector3.UP, deg_to_rad(node_deg))
	b = b.rotated(Vector3.RIGHT, deg_to_rad(inc_deg))
	b = b.rotated(Vector3.UP, deg_to_rad(arg_peri_deg))
	return b

func _clamp_e(e: float, max_e: float = 0.999) -> float:
	if e < 0.0: return 0.0
	if e > max_e: return max_e
	return e

func _norm(a: float) -> float:
	var x := fmod(a, TAU)
	if x < 0.0: x += TAU
	return x

func _safe_div(a: float, b: float) -> float:
	return a / (b if abs(b) > 1e-12 else (1e-12 if a >= 0.0 else -1e-12))

func _rebuild_orbit_line() -> void:
	
	_clear_orbit_line()
	if not orbit_line_enabled:
		return
	if _a_m <= 0.0:
		return

	
	var pts: PackedVector3Array = _ellipse_points_world(orbit_line_segments)

	# Matériau simple, non ombré, transparent
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = orbit_line_color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS

	var im := ImmediateMesh.new()
	if orbit_line_as_ribbon:
		# fin ruban extrudé dans le plan local de l’ellipse pour le rendre plus visible

		var half_w = max(orbit_line_ribbon_width_m, 0.0)
	
		im.surface_begin(Mesh.PRIMITIVE_TRIANGLES, mat)
		for i in range(pts.size()):
			var i2 := (i + 1) % pts.size()
			var p0 := pts[i]
			var p1 := pts[i2]
			var dir := (p1 - p0).normalized()
			
			var up := Vector3.UP
		
			if abs(dir.dot(up)) > 0.95:
				up = Vector3.RIGHT
			var side = dir.cross(up).normalized() * half_w

			
			var a = p0 - side
			var b = p0 + side
			var c = p1 + side
			var d = p1 - side

			im.surface_add_vertex(a); im.surface_add_vertex(b); im.surface_add_vertex(c)
			im.surface_add_vertex(a); im.surface_add_vertex(c); im.surface_add_vertex(d)
		im.surface_end()
	else:
	
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, mat)
		for p in pts:
			im.surface_add_vertex(p)
		
		im.surface_add_vertex(pts[0])
		im.surface_end()


	_orbit_line_node = MeshInstance3D.new()
	_orbit_line_node.mesh = im
	_orbit_line_node.top_level = true
	_orbit_line_node.name = "OrbitLine_%s" % name


	_orbit_line_node.global_transform = Transform3D.IDENTITY

	
	var host := get_parent() if get_parent() != null else get_tree().current_scene
	if host != null:
		host.add_child(_orbit_line_node)

func _clear_orbit_line() -> void:
	if _orbit_line_node and is_instance_valid(_orbit_line_node):
		_orbit_line_node.queue_free()
	_orbit_line_node = null

func _ellipse_points_world(segments: int) -> PackedVector3Array:
	var N = max(16, int(segments))
	var pts := PackedVector3Array()
	pts.resize(N)


	var a := _a_m
	var e = clamp(_e, 0.0, 0.999)
	var b := a * sqrt(1.0 - e * e)  # petit axe

	for i in range(N):
		var t := float(i) / float(N) * TAU
		var xp = a * (cos(t) - e)
		var zp := b * sin(t)
		var p_local := Vector3(xp, 0.0, zp)
		pts[i] = _orbit_center + (_basis * p_local)
	return pts
	
func _clear_beacon() -> void:
	if _beacon_node and is_instance_valid(_beacon_node):
		_beacon_node.queue_free()
	_beacon_node = null

func _rebuild_beacon() -> void:
	_clear_beacon()
	if not beacon_enabled:
		return

	# ----- HAUTEUR -----
	var h: float
	if beacon_auto_height and planet_settings:
		var extra_m = max(beacon_extra_km, 0.0) * 1000.0
		var radius_m = max(planet_settings.radius, 0.0)
		h = 2.0 * (radius_m + extra_m)    # traverse + dépasse
	else:
		h = max(beacon_height_m, 1.0)

	# ----- MESH -----
	var cyl := CylinderMesh.new()
	cyl.top_radius = max(beacon_thickness_m, 1.0)
	cyl.bottom_radius = cyl.top_radius
	cyl.height = h
	cyl.radial_segments = 32
	cyl.rings = 1

	# ----- MATÉRIAU -----
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = beacon_color
	mat.emission_enabled = true
	mat.emission = beacon_color * beacon_emission
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	# ----- INSTANCE -----
	_beacon_node = MeshInstance3D.new()
	_beacon_node.name = "PlanetBeacon_%s" % name
	_beacon_node.mesh = cyl
	_beacon_node.material_override = mat
	_beacon_node.visible = true

	if beacon_attach_to_planet:
	
		add_child(_beacon_node)
		_beacon_node.top_level = false
		_beacon_node.position = Vector3.ZERO  # centré : traverse la planète
	else:
		
		var host := get_tree().current_scene if get_tree() else get_parent()
		if host:
			host.add_child(_beacon_node)
		_beacon_node.top_level = true
		_beacon_node.global_position = global_position

	print("[BEACON] created h=%.0f m  r=%.0f m  attach=%s  parent=%s" %
		[h, beacon_thickness_m, ( "planet" if beacon_attach_to_planet else "world"),
		 (_beacon_node.get_parent().name if _beacon_node.get_parent() else "null")])
