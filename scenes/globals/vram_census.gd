class_name VramCensus
extends RefCounted
## Where the video memory goes: the lines ClientPerf prints as [CPerfV] (debug_perf=true), the answer
## to "the game takes 3 GB of VRAM" that the single vram= figure of the heartbeat cannot give.
##
## The engine's own list (RenderingServer::texture_debug_usage, the editor's Video RAM tab) is not
## bound to scripts, so this walks what the scene tree uses instead: the materials of every mesh,
## particle, decal and sprite, the environments and skies, the global shader parameters, the
## viewports. Each texture found is asked to the RenderingDevice for what the GPU really holds
## (size, mipmaps, layers, format), deduplicated by GPU texture, and charged to the first scene that
## uses it. A texture only a script holds (not in a material) is not seen: `unseen` = the engine's
## texture counter minus what was found, which also holds the renderer's own buffers (shadow
## atlases, glow and SSAO chains, GI, sky radiance, the depth buffers of each viewport). Meshes are
## the `buffers` figure, for which the engine keeps no per-mesh list.
##
## Walked a little per frame (step()) since a world has tens of thousands of nodes. Engine API only:
## ClientPerf is an autoload and must not name a gameplay class (CLAUDE.md).

const _MIB := 1048576.0
## Resources never worth opening: they hold no texture the 3D/2D scene draws with, or only the UI's.
const _SKIP_CLASSES: Array[String] = [
	"Script", "PackedScene", "Shader", "Font", "Theme", "Animation", "AnimationLibrary", "AudioStream",
	"Shape3D", "Shape2D", "Skin", "NavigationMesh", "World3D", "World2D", "MultiMesh", "Curve",
]

var _rd: RenderingDevice = RenderingServer.get_rendering_device()
var _formats: PackedStringArray = ClassDB.class_get_enum_constants("RenderingDevice", "DataFormat")
var _stack: Array = []  # Node, possibly freed by the time it is popped
var _opened: Dictionary = {}  # Resource instance id -> true
## RD texture id -> {bytes, shape, label, user, count}
var _textures: Dictionary = {}
var _nodes: int = 0
## Second pass, once the tree is done: every texture / material file of the project that is in
## ResourceLoader's cache, whoever holds it (a script, a cache, the warm-up), which the tree walk misses.
var _dirs: PackedStringArray = []
var _files: int = 0
## The texture / material files of the project, listed by the first census of the session (they do not
## change): the next ones only ask the cache about each.
static var _paths: PackedStringArray = []
static var _paths_done: bool = false
var _path_at: int = 0
## Mesh buffers, estimated from each surface's format and counts (no read-back from the GPU):
## mesh RID id -> true, and owner -> [bytes, count]; the biggest single meshes as [bytes, label].
var _meshes_seen: Dictionary = {}
var _mesh_by_user: Dictionary = {}
var _mesh_rows: Array = []
var _skinned_copies: int = 0
## Where the second pass finds what the scene does not show.
const _HELD := "<loaded, not in the scene>"
var _started_usec: int = 0
var _user: String = ""


func start(tree: SceneTree) -> void:
	_started_usec = Time.get_ticks_usec()
	_stack.append(tree.root)
	if not _paths_done:
		_dirs.append("res://")
	_user = "<root viewport>"
	_texture(tree.root.get_texture())
	if tree.root.world_3d:
		_resource(tree.root.world_3d.environment)
		_resource(tree.root.world_3d.fallback_environment)


## Walks for up to `budget_usec`; true once the tree and the project files are done.
func step(budget_usec: int) -> bool:
	var until: int = Time.get_ticks_usec() + budget_usec
	while not _stack.is_empty():
		# Untyped first: a node freed since an earlier frame of the walk (a chunk, an avatar streamed out)
		# is still in the stack, and assigning a freed instance to a typed variable is an error.
		var item: Variant = _stack.pop_back()
		if not is_instance_valid(item):
			continue
		var node := item as Node
		_nodes += 1
		_inspect(node)
		for child: Node in node.get_children(true):
			_stack.append(child)
		if Time.get_ticks_usec() >= until:
			return false
	while not _dirs.is_empty():
		_scan_dir(_dirs[_dirs.size() - 1])
		if Time.get_ticks_usec() >= until:
			return false
	_paths_done = true
	_user = _HELD
	while _path_at < _paths.size():
		var path: String = _paths[_path_at]
		_path_at += 1
		if ResourceLoader.has_cached(path):
			var res: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE)
			if res is Texture or res is Material:
				_resource(res)
		if Time.get_ticks_usec() >= until:
			return false
	return true


## One folder of the project: sub-folders queued, cached textures and materials registered. An
## exported game lists "x.png.import" and "x.tres.remap" where the editor lists "x.png" and "x.tres".
func _scan_dir(dir: String) -> void:
	_dirs.remove_at(_dirs.size() - 1)
	for sub: String in DirAccess.get_directories_at(dir):
		if not sub.begins_with("."):
			_dirs.append(dir.path_join(sub))
	for file: String in DirAccess.get_files_at(dir):
		_files += 1
		var path: String = dir.path_join(file.trim_suffix(".import").trim_suffix(".remap"))
		if path.ends_with(".tres") or path.ends_with(".res") or file.ends_with(".import"):
			_paths.append(path)


func lines(top: int = 40) -> PackedStringArray:
	var out: PackedStringArray = []
	var vram: int = int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))
	var tex_mem: int = int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED))
	var buf_mem: int = int(Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED))
	var found: int = 0
	var with_path: int = 0
	var by_format: Dictionary = {}
	var by_user: Dictionary = {}
	var by_folder: Dictionary = {}
	var rows: Array = []
	for t: Dictionary in _textures.values():
		var bytes: int = t["bytes"]
		found += bytes
		_add(by_format, t["format"], bytes)
		_add(by_user, t["user"], bytes)
		if t["path"] != "":
			with_path += bytes
			_add(by_folder, _folder(t["path"]), bytes)
		rows.append(t)
	out.append((
		"[CPerfV] vram=%.0f MiB = textures %.0f + buffers (meshes) %.0f + other %.0f"
		+ " | textures found %.0f (n=%d, imported %.0f, made at run time %.0f)"
		+ " + unseen %.0f (renderer buffers: shadows, glow, GI, depth; script-only textures)"
		+ " | walked %d nodes, %d files in %.1f s"
	) % [
		vram / _MIB, tex_mem / _MIB, buf_mem / _MIB, (vram - tex_mem - buf_mem) / _MIB,
		found / _MIB, rows.size(), with_path / _MIB, (found - with_path) / _MIB, (tex_mem - found) / _MIB,
		_nodes, _files, (Time.get_ticks_usec() - _started_usec) / 1e6,
	])
	var mesh_total: int = 0
	for row: Array in _mesh_by_user.values():
		mesh_total += int(row[0])
	out.append((
		"[CPerfV] meshes found ~%.0f MiB of buffers %.0f (estimate: no LODs, no blend shapes counted twice;"
		+ " %d skinned instances' own copy included) | by owner: %s"
	) % [mesh_total / _MIB, buf_mem / _MIB, _skinned_copies, _top(_mesh_by_user, 20)])
	_mesh_rows.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	for i: int in mini(15, _mesh_rows.size()):
		out.append("[CPerfV] mesh #%d %.1f MiB %s" % [i + 1, _mesh_rows[i][0] / _MIB, _mesh_rows[i][1]])
	out.append("[CPerfV] by format: %s" % _top(by_format, 12))
	out.append("[CPerfV] by folder: %s" % _top(by_folder, 25))
	out.append("[CPerfV] by first user: %s" % _top(by_user, 25))
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["bytes"] > b["bytes"])
	for i: int in mini(top, rows.size()):
		var t: Dictionary = rows[i]
		out.append("[CPerfV] #%d %.1f MiB %s %s | %s" % [
			i + 1, t["bytes"] / _MIB, t["shape"], t["path"] if t["path"] != "" else "<run time>", t["user"]])
	return out


# ------------------------------------------------------------------
# Walk
# ------------------------------------------------------------------

func _inspect(node: Node) -> void:
	if node is GeometryInstance3D:
		_user = _owner_of(node)
		var gi := node as GeometryInstance3D
		_resource(gi.material_override)
		_resource(gi.material_overlay)
		if node is MeshInstance3D:
			var mi := node as MeshInstance3D
			for i: int in mi.get_surface_override_material_count():
				_resource(mi.get_surface_override_material(i))
			_mesh(mi.mesh)
			_mesh_buffers(mi.mesh, mi.get_node_or_null(mi.skeleton) is Skeleton3D, node)
		elif node is MultiMeshInstance3D:
			var mm: MultiMesh = (node as MultiMeshInstance3D).multimesh
			if mm:
				_mesh(mm.mesh)
				_mesh_buffers(mm.mesh, false, node)
				# Per instance: a 3x4 transform, plus a colour and custom data when used (floats).
				_charge_mesh(node, mm.instance_count * 4 * (12 + (4 if mm.use_colors else 0)
						+ (4 if mm.use_custom_data else 0)), "multimesh x%d" % mm.instance_count)
		elif node is GPUParticles3D:
			var p := node as GPUParticles3D
			_resource(p.process_material)
			for i: int in p.draw_passes:
				_mesh(p.get_draw_pass_mesh(i))
		elif node is SpriteBase3D or node is CSGShape3D:
			_properties(node)
	elif node is CanvasItem:
		# The interface is thousands of nodes: only what draws a texture of its own, not every property.
		if (node as CanvasItem).is_visible_in_tree() and (node is TextureRect or node is Sprite2D
				or node is NinePatchRect or node is TextureButton or node is TextureProgressBar):
			_user = _owner_of(node)
			_properties(node)
	elif node is Decal or node is FogVolume or node is WorldEnvironment or node is Camera3D:
		_user = _owner_of(node)
		_properties(node)
	elif node is Viewport:
		_user = "<viewport %s>" % node.name
		_texture((node as Viewport).get_texture())


func _mesh(mesh: Mesh) -> void:
	if mesh == null or _opened.has(mesh.get_instance_id()):
		return
	_opened[mesh.get_instance_id()] = true
	for i: int in mesh.get_surface_count():
		_resource(mesh.surface_get_material(i))


## The GPU buffers of [param mesh] (once per mesh), plus the copy every skinned instance has of its
## vertex stream (the skeleton deforms into it). Strides as RenderingServer lays them out: vertex stream
## position 12 + normal/tangent 8 (compressed 8 + 4), attributes colour 4, each UV 8 (compressed 4),
## each custom 4-16, skin 16 (32 with 8 weights), index 2 or 4 bytes, each blend shape one vertex stream.
func _mesh_buffers(mesh: Mesh, skinned: bool, node: Node) -> void:
	var am := mesh as ArrayMesh
	if am == null:
		return
	var first: bool = not _meshes_seen.has(am.get_rid().get_id())
	_meshes_seen[am.get_rid().get_id()] = true
	var bytes: int = 0
	var copy: int = 0
	var verts_total: int = 0
	for s: int in am.get_surface_count():
		var f: int = am.surface_get_format(s)
		var verts: int = am.surface_get_array_len(s)
		var compressed: bool = f & Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES != 0
		var stream: int = (8 + 4) if compressed else (12 + 8)
		if f & Mesh.ARRAY_FORMAT_BONES:
			copy += verts * stream
		verts_total += verts
		if not first:
			continue
		var attr: int = 4 if f & Mesh.ARRAY_FORMAT_COLOR else 0
		attr += (4 if compressed else 8) * (int(f & Mesh.ARRAY_FORMAT_TEX_UV != 0) + int(f & Mesh.ARRAY_FORMAT_TEX_UV2 != 0))
		for c: int in 4:
			if f & (Mesh.ARRAY_FORMAT_CUSTOM0 << c):
				var kind: int = (f >> (Mesh.ARRAY_FORMAT_CUSTOM_BASE + c * Mesh.ARRAY_FORMAT_CUSTOM_BITS)) & Mesh.ARRAY_FORMAT_CUSTOM_MASK
				attr += [4, 4, 4, 8, 4, 8, 12, 16][kind] if kind < 8 else 16
		var skin: int = 0
		if f & Mesh.ARRAY_FORMAT_BONES:
			skin = 32 if f & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS else 16
		var idx: int = am.surface_get_array_index_len(s) * (2 if verts <= 65535 else 4)
		bytes += verts * (stream + attr + skin) + idx + verts * stream * am.get_blend_shape_count()
	if not skinned:
		copy = 0
	elif copy > 0:
		_skinned_copies += 1
	if first or copy > 0:
		_charge_mesh(node, (bytes if first else 0) + copy, "%d verts %s%s" % [
			verts_total, "" if first else "(shared) ", "skinned " if skinned else ""])


func _charge_mesh(node: Node, bytes: int, what: String) -> void:
	if bytes <= 0:
		return
	var owner: String = _owner_of(node)
	_add(_mesh_by_user, owner, bytes)
	_mesh_rows.append([bytes, "%s | %s/%s" % [what, owner, node.name]])
	if _mesh_rows.size() > 400:
		_mesh_rows.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
		_mesh_rows.resize(100)


func _resource(res: Resource) -> void:
	if res == null or _opened.has(res.get_instance_id()):
		return
	if res is Texture:
		_texture(res as Texture)
		return
	_opened[res.get_instance_id()] = true
	for cls: String in _SKIP_CLASSES:
		if res.is_class(cls):
			return
	if res is Mesh:
		_opened.erase(res.get_instance_id())
		_mesh(res as Mesh)
		return
	_properties(res)


func _properties(obj: Object) -> void:
	for prop: Dictionary in obj.get_property_list():
		var t: int = prop["type"]
		if t == TYPE_OBJECT or t == TYPE_ARRAY:
			_value(obj.get(prop["name"]))


func _value(v: Variant) -> void:
	if v is Resource:
		_resource(v as Resource)
	elif v is Array:
		for item: Variant in v:
			if item is Resource:
				_resource(item as Resource)


func _texture(tex: Texture) -> void:
	if tex == null:
		return
	_opened[tex.get_instance_id()] = true
	if tex is AtlasTexture:
		_texture((tex as AtlasTexture).atlas)
		return
	if _rd == null:
		return
	var rd_rid: RID = RenderingServer.texture_get_rd_texture(tex.get_rid())
	if not rd_rid.is_valid():
		return
	var key: int = rd_rid.get_id()
	if _textures.has(key):
		return
	var f: RDTextureFormat = _rd.texture_get_format(rd_rid)
	var fmt: String = _formats[f.format].trim_prefix("DATA_FORMAT_") if f.format < _formats.size() else str(f.format)
	var layers: int = maxi(1, f.array_layers) * maxi(1, f.depth)
	_textures[key] = {
		"bytes": _bytes(f, fmt),
		"format": fmt,
		"shape": "%dx%d%s %s mips=%d" % [f.width, f.height, ("x%d" % layers) if layers > 1 else "", fmt, f.mipmaps],
		"path": tex.resource_path,
		"user": _user,
	}


## What the GPU holds for this texture: every mip level, layer and sample.
static func _bytes(f: RDTextureFormat, fmt: String) -> int:
	var texels: float = 0.0
	for m: int in maxi(1, f.mipmaps):
		texels += maxf(1.0, f.width >> m) * maxf(1.0, f.height >> m)
	var layers: int = maxi(1, f.array_layers) * maxi(1, f.depth)
	return int(texels * _bits_per_texel(fmt) / 8.0 * layers * (1 << f.samples))


## From the RenderingDevice format name: "R8G8B8A8_UNORM" = 32, "BC7_UNORM_BLOCK" = 8, "PACK32" = 32.
static func _bits_per_texel(fmt: String) -> float:
	if fmt.begins_with("BC1") or fmt.begins_with("BC4") or fmt.begins_with("EAC_R11_") \
			or fmt.begins_with("ETC2_R8G8B8_") or fmt.begins_with("ETC2_R8G8B8A1"):
		return 4.0
	if fmt.begins_with("BC") or fmt.begins_with("ETC2") or fmt.begins_with("EAC"):
		return 8.0
	if fmt.begins_with("ASTC_"):
		var dims: PackedStringArray = fmt.get_slice("_", 1).split("x")
		return 128.0 / maxf(1.0, float(dims[0].to_int() * dims[1].to_int()))
	var pack: int = fmt.find("PACK")
	if pack >= 0:
		return float(fmt.substr(pack + 4).to_int())
	var bits: int = 0
	var re := RegEx.create_from_string("[RGBADSX](\\d+)")
	for m: RegExMatch in re.search_all(fmt.get_slice("_", 0) + "_" + fmt.get_slice("_", 2)):
		bits += m.get_string(1).to_int()
	return float(maxi(bits, 8))


static func _owner_of(node: Node) -> String:
	var n: Node = node
	while n != null:
		if n.scene_file_path != "":
			return n.scene_file_path.trim_prefix("res://")
		n = n.owner if n.owner != null else n.get_parent()
	return String(node.name)


# ------------------------------------------------------------------
# Report helpers
# ------------------------------------------------------------------

static func _add(into: Dictionary, key: String, bytes: int) -> void:
	var cur: Array = into.get(key, [0, 0])
	into[key] = [int(cur[0]) + bytes, int(cur[1]) + 1]


static func _top(groups: Dictionary, n: int) -> String:
	var keys: Array = groups.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return groups[a][0] > groups[b][0])
	var parts: PackedStringArray = []
	for i: int in mini(n, keys.size()):
		parts.append("%s=%.1f MiB x%d" % [keys[i], groups[keys[i]][0] / _MIB, groups[keys[i]][1]])
	return ", ".join(parts)


## "res://assets/_universe/props/furniture/x.png" -> "assets/_universe/props" (3 levels); a
## sub-resource "res://a/b.tscn::ImageTexture_x" -> its scene file.
static func _folder(path: String) -> String:
	if path.contains("::"):
		return path.get_slice("::", 0).trim_prefix("res://")
	return "/".join(path.trim_prefix("res://").get_base_dir().split("/").slice(0, 3))
