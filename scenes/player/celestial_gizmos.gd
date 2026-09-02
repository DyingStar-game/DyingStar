class_name CelestialGizmos
extends Node3D

## Client-only orientation aid: a labelled marker floating in the direction of the system star and of
## every planet/moon currently loaded. The bodies sit at astronomic distances (~3e10), so a marker at
## the real position would be an invisible speck; instead each marker is pinned a fixed distance in
## FRONT of the camera along the true direction to its body, and drawn on top of everything, so it
## reads like an editor gizmo. Toggled from Settings > General; created by PlayerClient for the owner.
##
## Each marker is top_level, so it ignores this node's (and the camera's) transform and lives directly
## in world space. Its world position is the camera position plus the direction to the body, so on a
## pure camera rotation the marker does not move at all — you turn to face it. Binding a marker to the
## camera's orientation instead makes it swim, because the orientation read in _process lags the frame
## the camera is actually rendered with. Only the direction, from subtracting two float64 world
## positions, carries meaning; the fixed 120 m distance is cosmetic.

## Distance (m) in front of the camera at which the markers float. Purely cosmetic — only the
## direction carries meaning.
const MARKER_DISTANCE: float = 120.0
const STAR_COLOR: Color = Color(1.0, 0.82, 0.28)  # amber
const PLANET_COLOR: Color = Color(0.45, 0.72, 1.0)  # blue
const MOON_COLOR: Color = Color(0.45, 0.9, 0.5)  # green
## Rebuild the body list this often (s): bodies stream in and out through GORC, so the set changes.
const RESCAN_PERIOD: float = 1.0

## Kept for symmetry with the other player-owned client nodes; the camera is read via get_parent().
var player: Node3D = null
var _markers: Dictionary = {}  # body instance id -> marker Node3D (a sphere with a Label3D child)
var _rescan_accum: float = RESCAN_PERIOD

func _ready() -> void:
	if OS.has_feature("dedicated_server"):
		set_process(false)
		return
	# Run after the camera has been oriented this frame, so the marker positions use its final pose.
	process_priority = 100
	visible = SettingsManager.is_celestial_gizmos()
	SettingsManager.celestial_gizmos_changed.connect(_on_toggled)

func _on_toggled(on: bool) -> void:
	visible = on
	if not on:
		_clear()  # drop the markers so nothing lingers / keeps updating while hidden

func _process(delta: float) -> void:
	if not visible:
		return
	_rescan_accum += delta
	if _rescan_accum >= RESCAN_PERIOD:
		_rescan_accum = 0.0
		_sync_markers()
	var cam: Node3D = _camera()
	if cam == null:
		return
	var eye: Vector3 = cam.global_position
	var cam_up: Vector3 = cam.global_transform.basis.y
	for id: int in _markers:
		var body: Node3D = instance_from_id(id) as Node3D
		var marker: Node3D = _markers[id]
		if not is_instance_valid(body):
			continue
		# Subtract the two float64 world positions FIRST (exact at ~3e10), then pin the marker that
		# direction from the eye. The marker is top_level, so this world position is used as-is and no
		# parent rotation can move it: on a pure camera turn the eye is fixed, so the marker is too.
		var to_body: Vector3 = body.global_position - eye
		if to_body.length_squared() < 1.0:
			continue
		var dist_label: Node = marker.get_node_or_null("dist")
		if dist_label is Label3D:
			(dist_label as Label3D).text = Globals.format_distance(
					_surface_distance(body, eye, to_body.length()))
		var dir: Vector3 = to_body.normalized()
		# Face the marker (and its label child) at the camera HERE, in double precision, instead of
		# leaving it to the Label3D billboard: the shader billboard subtracts two ~3e10 positions in
		# float32, which frémit. +Z points at the eye (Label3D reads from +Z), up follows the camera.
		var z_axis: Vector3 = -dir
		var x_axis: Vector3 = cam_up.cross(z_axis)
		if x_axis.length_squared() < 0.000001:
			x_axis = cam.global_transform.basis.x
		x_axis = x_axis.normalized()
		var y_axis: Vector3 = z_axis.cross(x_axis).normalized()
		marker.global_transform = Transform3D(
				Basis(x_axis, y_axis, z_axis), eye + dir * MARKER_DISTANCE)

## Reconcile the marker set with the bodies currently in the tree: add markers for new bodies, drop
## markers whose body has despawned.
func _sync_markers() -> void:
	var bodies: Dictionary = {}  # instance id -> body node
	_collect_bodies(NetworkOrchestrator.universe_scene, bodies)
	for id: int in _markers.keys():
		if not bodies.has(id):
			_markers[id].queue_free()
			_markers.erase(id)
	for id: int in bodies:
		if not _markers.has(id):
			var body: Node3D = bodies[id]
			# The same two properties the system chart reads, so a body is named and coloured identically
			# wherever it shows up. body.name is Horizon's code ("P3_M2"), never what to show a player.
			var label_text: String = body.name
			var colour: Color = _body_color(body)
			if body is Planet:
				var planet: Planet = body as Planet
				if planet.display_name != "":
					label_text = planet.display_name
				colour = planet.map_color
			var marker: Node3D = _make_marker(label_text, colour)
			add_child(marker)
			_markers[id] = marker

## Colour a body by kind: amber star, blue planet, green moon. A moon is a Planet nested under another
## Planet (its position is planet-relative), so having a Planet ancestor is what tells the two apart.
func _body_color(body: Node3D) -> Color:
	if not (body is Planet):
		return STAR_COLOR
	var ancestor: Node = body.get_parent()
	while ancestor != null:
		if ancestor is Planet:
			return MOON_COLOR
		ancestor = ancestor.get_parent()
	return PLANET_COLOR

## Walk the universe scene for celestial bodies: any Planet node (planets AND moons share the class),
## plus the star mesh (a MeshInstance3D whose name contains "star"). A moon is parented UNDER its
## planet (its position is planet-relative), so we must recurse INTO a planet to find its moons — but
## we skip the PlanetTerrain subtree, which holds the heavy chunk nodes and no bodies.
func _collect_bodies(node: Node, out: Dictionary) -> void:
	if node == null:
		return
	for child: Node in node.get_children():
		if child is PlanetTerrain:
			continue  # terrain chunks, never another body — do not walk them
		if child is Planet:
			out[child.get_instance_id()] = child
		elif child is MeshInstance3D and (child.name as String).to_lower().contains("star"):
			out[child.get_instance_id()] = child
		_collect_bodies(child, out)

## One marker = a small always-on-top sphere plus a fixed-size billboard label with the body name.
func _make_marker(body_name: String, color: Color) -> Node3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.no_depth_test = true  # gizmo: always visible, even through terrain and buildings
	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	var marker: MeshInstance3D = MeshInstance3D.new()
	marker.mesh = sphere
	marker.material_override = mat
	marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	marker.top_level = true  # live in world space, immune to the camera/player transform
	var label: Label3D = Label3D.new()
	label.text = body_name
	label.modulate = color
	# Billboard DISABLED on purpose: the marker is oriented at the camera in _process, in double
	# precision. The shader billboard and fixed_size both do float32 maths on the ~3e10 position and
	# make the text jitter; plain perspective at the fixed 120 m distance keeps its size steady.
	label.no_depth_test = true
	label.font_size = 48
	label.pixel_size = 0.08  # world size of a font pixel -> ~3.8 m tall text at the 120 m marker
	# Bottom-aligned and sitting just above the distance line, so the two never overlap whatever the
	# name length or font size (the distance below is top-aligned just under this anchor).
	label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	label.position = Vector3(0.0, 3.6, 0.0)
	marker.add_child(label)
	# Distance readout, smaller, under the name. Updated every frame in _process (named so it is found).
	var dist: Label3D = Label3D.new()
	dist.name = "dist"
	dist.modulate = color
	dist.no_depth_test = true
	dist.font_size = 48
	dist.pixel_size = 0.045  # ~55% of the name size
	# Top-aligned and pulled UP into the name's baseline so the distance tucks right under the name text
	# (Label3D leaves descender/line space below the glyphs, so a flush anchor still looks gappy).
	dist.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	dist.position = Vector3(0.0, 4.8, 0.0)
	marker.add_child(dist)
	return marker

## Distance from the eye to the body's SURFACE, not its centre: so the number reads as "how far above
## the ground" (~0 when you stand on it), not "how far to the core" (= the radius). Close in, it samples
## the actual terrain height (accounts for relief); far away, the base radius is already accurate to
## within the terrain height, so we skip the heightmap sample. The star keeps the centre distance.
func _surface_distance(body: Node3D, eye: Vector3, centre_distance: float) -> float:
	if not (body is Planet) or (body as Planet).planet_data == null:
		return centre_distance
	var base_altitude: float = centre_distance - (body as Planet).planet_data.radius
	if base_altitude < 100000.0:  # within 100 km: refine with the real ground height
		return maxf((body as Planet).surface_altitude_of(eye), 0.0)
	return base_altitude

## Distance, formatted by the SHARED rule (Globals.format_distance) so a body reads identically here
## and in the system chart. Kept as a one-line seam rather than calling Globals inline: the call site
## in _process is a hot loop and this keeps the intent named.

## The camera this node is parented under (created there by PlayerClient); its position is the eye
## from which body directions are measured.
func _camera() -> Node3D:
	return get_parent() as Node3D

func _clear() -> void:
	for id: int in _markers:
		_markers[id].queue_free()
	_markers.clear()
