@tool
class_name CaveSpawner
## Spawns GemCave instances with geometry, collision, materials, and lighting.
##
## Extracted from PlanetTerrain to keep all cave-biome logic self-contained
## inside the `scenes/planet/cave/` folder.  Uses constants from both
## [CaveTerrain] (entrance dimensions) and [GemCave] (geometry parameters).

# ── Cached materials (created once, shared across all caves) ──────

static var _wall_mat: Material
static var _crystal_mat: Material


# ── Public API ─────────────────────────────────────────────────────

## Spawn a GemCave instance at the centroid of a cave biome zone.
## Returns the root [StaticBody3D] node ready to be added to the scene tree,
## or null if the zone is invalid.
static func spawn(planet_data: PlanetData, chunk_info: Dictionary, zone: Dictionary) -> StaticBody3D:
	# Compute the centroid of the biome polygon (lon/lat degrees).
	var poly: PackedVector2Array = zone.get("polygon", PackedVector2Array())
	if poly.size() < 3:
		return null

	var centroid := Vector2.ZERO
	for pt in poly:
		centroid += pt
	centroid /= float(poly.size())

	# Convert lon/lat centroid to a planet-surface direction + position.
	var lon_rad := deg_to_rad(centroid.x)
	var lat_rad := deg_to_rad(centroid.y)
	var cave_dir := Vector3(
		cos(lat_rad) * cos(lon_rad),
		sin(lat_rad),
		cos(lat_rad) * sin(lon_rad)
	).normalized()
	var surface_height: float
	# Use per-chunk heightmap tiles for accurate elevation (the global
	# heightmap may be absent or low-res, giving height=0).
	if chunk_info.has("nside"):
		surface_height = planet_data.sample_height_for_direction(cave_dir)
	else:
		var fuv := PlanetData.sphere_to_cube(cave_dir)
		if fuv.face == chunk_info.face:
			surface_height = planet_data.sample_height_for_chunk(
				fuv.face, fuv.u, fuv.v,
				chunk_info.u_min, chunk_info.u_max,
				chunk_info.v_min, chunk_info.v_max)
		else:
			surface_height = planet_data.sample_height_at(cave_dir)
	# Place cave origin at the depressed terrain level so the entrance
	# mouth sits flush with the depression bowl.  The terrain is pushed
	# down by ENTRANCE_DEPTH_M at the centroid; the cave geometry then
	# starts its tunnel from ENTRANCE_DIP below this new level.
	var depressed_height := surface_height - CaveTerrain.ENTRANCE_DEPTH_M
	var cave_world_pos := cave_dir * (planet_data.radius + depressed_height)

	# Build an orientation basis: Y = planet up (cave_dir),
	# Z = arbitrary tangent (entrance direction), X = cross.
	var up := cave_dir
	var north := Vector3.UP
	if absf(up.dot(north)) > 0.95:
		north = Vector3.RIGHT
	var tangent_x := up.cross(north).normalized()
	var tangent_z := tangent_x.cross(up).normalized()
	var basis := Basis(tangent_x, up, tangent_z)

	# Generate cave geometry.
	var cave_data := GemCave.generate()
	var cave_mesh: ArrayMesh = cave_data["mesh"]
	var cave_shape: ConcavePolygonShape3D = cave_data["shape"]
	var crystal_mesh: ArrayMesh = cave_data["crystal_mesh"]

	# Ensure materials are created (lazy init, shared across instances).
	if _wall_mat == null:
		_wall_mat = GemCave.create_wall_material()
	if _crystal_mat == null:
		_crystal_mat = GemCave.create_crystal_material()

	# Assign materials to mesh surfaces.
	if cave_mesh.get_surface_count() > 0:
		cave_mesh.surface_set_material(0, _wall_mat)
	if crystal_mesh.get_surface_count() > 0:
		crystal_mesh.surface_set_material(0, _crystal_mat)

	# Build the scene tree:
	#   StaticBody3D (root, positioned + oriented on planet surface)
	#     ├─ MeshInstance3D (cave walls)
	#     ├─ MeshInstance3D (crystals)
	#     ├─ CollisionShape3D
	#     └─ OmniLight3D × 9 (dramatic grotto lighting)
	var cave_root := StaticBody3D.new()
	cave_root.name = chunk_info.key + "_cave"
	cave_root.global_transform = Transform3D(basis, cave_world_pos)

	var wall_mi := MeshInstance3D.new()
	wall_mi.mesh = cave_mesh
	wall_mi.name = "CaveWalls"
	wall_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cave_root.add_child(wall_mi)

	if crystal_mesh.get_surface_count() > 0:
		var crystal_mi := MeshInstance3D.new()
		crystal_mi.mesh = crystal_mesh
		crystal_mi.name = "Crystals"
		crystal_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		cave_root.add_child(crystal_mi)

	var col := CollisionShape3D.new()
	col.shape = cave_shape
	col.name = "CaveCollision"
	cave_root.add_child(col)

	# ── Dramatic grotto lighting ──────────────────────────────────
	_add_cave_lights(cave_root)

	print("[CAVE] Spawned gemstone cave at lon=%.4f lat=%.4f (chunk %s)  surface_h=%.1f depressed_h=%.1f pos=%s" % [
		centroid.x, centroid.y, chunk_info.key, surface_height, depressed_height, cave_world_pos])

	return cave_root


# ── Internal helpers ───────────────────────────────────────────────

## Add 9 OmniLight3D nodes to the cave root for dramatic grotto atmosphere.
static func _add_cave_lights(cave_root: Node3D) -> void:
	# Colour palette for cave lights.
	var col_warm_gold := Color(1.0, 0.85, 0.55)     # warm golden
	var col_amber := Color(1.0, 0.75, 0.4)          # deep amber
	var col_entrance := Color(0.9, 0.88, 0.8)       # daylight spill
	var col_crystal := Color(0.85, 0.65, 0.35)      # crystal glow

	# 1. Entrance daylight spill — bright warm light at the cave mouth.
	var l_entrance := OmniLight3D.new()
	l_entrance.name = "EntranceDaylight"
	l_entrance.light_color = col_entrance
	l_entrance.light_energy = 3.0
	l_entrance.omni_range = GemCave.ENTRANCE_ARCH_HEIGHT * 8.0
	l_entrance.omni_attenuation = 0.8
	l_entrance.position = Vector3(0.0, GemCave.ENTRANCE_ARCH_HEIGHT * 0.5, -5.0)
	l_entrance.shadow_enabled = true
	cave_root.add_child(l_entrance)

	# 2–5. Tunnel lights — four warm lights evenly spaced along the tunnel.
	var tunnel_light_count := 4
	for li in tunnel_light_count:
		var t := float(li + 1) / float(tunnel_light_count + 1)
		var descent := t * t * (3.0 - 2.0 * t)
		var lz := t * GemCave.TUNNEL_LENGTH
		var ly := -GemCave.ENTRANCE_DIP - descent * (GemCave.TUNNEL_DEPTH - GemCave.ENTRANCE_DIP)
		var arch_h := lerpf(GemCave.ENTRANCE_ARCH_HEIGHT, GemCave.CHAMBER_HEIGHT * 0.7, t)
		var l_tunnel := OmniLight3D.new()
		l_tunnel.name = "TunnelLight_%d" % li
		# Gradually shift from warm daylight to deeper amber.
		l_tunnel.light_color = col_entrance.lerp(col_amber, t)
		l_tunnel.light_energy = lerpf(2.5, 1.8, t)
		l_tunnel.omni_range = lerpf(GemCave.ENTRANCE_RADIUS * 3.0, GemCave.CHAMBER_RADIUS * 0.8, t)
		l_tunnel.omni_attenuation = 1.2
		# Position at roughly 60% of arch height (upper third of tunnel).
		l_tunnel.position = Vector3(0.0, ly + arch_h * 0.6, lz)
		l_tunnel.shadow_enabled = li % 2 == 0  # shadows on alternating lights
		cave_root.add_child(l_tunnel)

	# 6. Main chamber centre light — the dramatic golden glow.
	var l_chamber := OmniLight3D.new()
	l_chamber.name = "ChamberGlow"
	l_chamber.light_color = col_warm_gold
	l_chamber.light_energy = 4.0
	l_chamber.omni_range = GemCave.CHAMBER_RADIUS * 1.8
	l_chamber.omni_attenuation = 1.0
	l_chamber.position = Vector3(0.0,
		-GemCave.TUNNEL_DEPTH + GemCave.CHAMBER_HEIGHT * 0.55,
		GemCave.TUNNEL_LENGTH)
	l_chamber.shadow_enabled = true
	cave_root.add_child(l_chamber)

	# 7–8. Side accent lights in the chamber (warm amber, off-centre).
	for li in 2:
		var angle := PI * 0.5 + float(li) * PI  # left and right
		var l_side := OmniLight3D.new()
		l_side.name = "ChamberSide_%d" % li
		l_side.light_color = col_amber
		l_side.light_energy = 2.0
		l_side.omni_range = GemCave.CHAMBER_RADIUS * 1.2
		l_side.omni_attenuation = 1.3
		l_side.position = Vector3(
			cos(angle) * GemCave.CHAMBER_RADIUS * 0.5,
			-GemCave.TUNNEL_DEPTH + GemCave.CHAMBER_HEIGHT * 0.3,
			GemCave.TUNNEL_LENGTH + sin(angle) * GemCave.CHAMBER_RADIUS * 0.3)
		cave_root.add_child(l_side)

	# 9. Crystal glow light — emissive feel near crystal wall clusters.
	var l_crystal := OmniLight3D.new()
	l_crystal.name = "CrystalGlow"
	l_crystal.light_color = col_crystal
	l_crystal.light_energy = 2.5
	l_crystal.omni_range = GemCave.CHAMBER_RADIUS * 0.8
	l_crystal.omni_attenuation = 1.5
	l_crystal.position = Vector3(0.0,
		-GemCave.TUNNEL_DEPTH + GemCave.CHAMBER_HEIGHT * 0.25,
		GemCave.TUNNEL_LENGTH + GemCave.CHAMBER_RADIUS * 0.4)
	cave_root.add_child(l_crystal)
