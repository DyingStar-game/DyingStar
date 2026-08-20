@tool
class_name ServerPropsIO
extends RefCounted

## Import / export / clear the SERVER (network) props of the edited scene.
##
## Model: the EDITED SCENE'S ROOT is itself the top server prop (it carries a `uuid`). On import we
## record the matching JSON object's identity for that root (never recreate it), and put every other
## object under a single marker node named `dyingstarNetwork` so the level designer sees what gets
## serialized. Export emits the root then walks the marker's subtree; clear deletes the marker.
##
## IMPORTANT — no node metadata: the editor hides a node's non-exported script vars (type_name, uuid),
## and adding metadata to a runtime-instanced node crashes the .tscn save. So we keep each prop's
## identity (type, uuid, original object_data) in a SESSION TABLE here, keyed by instance id, instead
## of on the nodes. The nodes stay metadata-free, so they save exactly like hand-placed instances.

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")
## Marker node grouping every imported/networked prop. Created on import; NOT written to the JSON.
const NETWORK_NODE_NAME := "dyingstarNetwork"
## The PropSync component every prop carries as a child (see scenes/globals/prop_sync.gd). It holds
## the networked `type_name` / `uuid`; the prop itself is its PARENT (the body), never this node.
const PROP_SYNC_NODE_NAME := "PropSync"
## Cache of the per-type network property allowlists, fetched from horizonserver's <type>_def.json
## files by the editor plugin. {type: [property names]}. Empty until "Update network definitions".
const DEFS_CACHE := "res://addons/dyingstar/network_defs.json"

## Session identity table: node instance id -> {type, uuid, data}. Populated on import, read on
## export, emptied on clear. Kept OFF the nodes so saving the scene never serializes it (no crash).
static var _identity: Dictionary = {}

# ── Export ──────────────────────────────────────────────────────────────────

static func export_to_json(scene_root: Node, path: String) -> Dictionary:
	if scene_root == null or _node_uuid(scene_root) == "":
		return {"ok": false, "error":
			"The scene root has no uuid. Open the scene of a server prop (its root must carry a uuid) before exporting."}
	var defs := load_network_defs()
	if defs.is_empty():
		return {"ok": false, "error": "Network definitions not loaded — run 'Update network definitions' first."}
	# The scene root is the top prop: emit it (server position kept from its recorded data), then
	# collect the props under the dyingstarNetwork marker — that subtree is what gets serialized.
	var objects: Array = []
	var root_pid := str(_stored_data(scene_root).get("parent_id", ""))
	objects.append(_build_object(scene_root, root_pid, true))
	var marker := _find_marker(scene_root)
	if marker != null:
		_collect(marker, _root_uuid_of(scene_root), objects)
	# Keep only the network properties each type declares in its horizonserver <type>_def.json.
	_filter_by_defs(objects, defs)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "Cannot write to %s" % path}
	f.store_string(JSON.stringify(objects, "    "))
	f.close()
	return {"ok": true, "count": objects.size()}

static func _collect(node: Node, parent_id: String, objects: Array) -> void:
	for child in node.get_children():
		if _is_prop_sync(child):
			continue  # a prop's own networking component, not a prop of its own
		if _is_prop(child):
			var cid := _prop_uuid(child)
			# A prop that has prop children must own a uuid so they can reference it as parent.
			if cid == "" and _has_prop_descendant(child):
				cid = UUID_UTIL.v4()
				var e: Dictionary = _identity.get(child.get_instance_id(), {})
				e["uuid"] = cid
				_identity[child.get_instance_id()] = e
			objects.append(_build_object(child, parent_id))
			_collect(child, (cid if cid != "" else parent_id), objects)
		else:
			# A plain grouping node (incl. the dyingstarNetwork marker): keep walking, parent unchanged.
			_collect(child, parent_id, objects)

static func _build_object(node: Node, parent_id: String, is_anchor := false) -> Dictionary:
	var data: Dictionary = {}
	# 1) Fidelity: replay fields imported but not editable in Godot (e.g. spawn_point).
	var stored := _stored_data(node)
	for k in stored:
		data[k] = stored[k]
	# 2) Common, always-current fields.
	if node.name != "" and not String(node.name).is_valid_int():
		data["name"] = String(node.name)
	if not data.has("parent_id"):
		data["parent_id"] = parent_id
	# Keep the scenename from the recorded data when the node has no scene_file_path (scene root).
	var scenename := String(node.scene_file_path).trim_prefix("res://")
	if scenename != "":
		data["scenename"] = scenename
	# The anchor (scene root) is edited at 0,0,0; its real server position lives in the recorded data
	# (replayed above), so keep it. Children use their live transform. Fall back to the transform.
	# Only a Node3D has a transform — a spatial-less prop keeps whatever the recorded data holds
	# (reading `position` off a plain Node aborts this function and silently emits {}).
	if node is Node3D:
		if not is_anchor or not data.has("position"):
			data["position"] = _v3(node.position)
		if not is_anchor or not data.has("rotation"):
			data["rotation"] = _v3(node.rotation)
	# 3) Type-specific fields (opt-in), override the stale recorded values with current ones.
	if node.has_method("server_export_data"):
		var extra: Dictionary = node.server_export_data()
		for k in extra:
			data[k] = extra[k]
	var uuid_val := _prop_uuid(node)
	return {
		"object_type": _prop_type(node),
		"object_uuid": (uuid_val if uuid_val != "" else null),
		"object_data": data,
	}

# ── Import ──────────────────────────────────────────────────────────────────

static func import_from_json(scene_root: Node, path: String) -> Dictionary:
	if scene_root == null:
		return {"ok": false, "error": "Open a scene first."}
	if not has_network_defs():
		return {"ok": false, "error": "Network definitions not loaded — run 'Update network definitions' first."}
	# The scene's ROOT node is the anchor: it must already BE a server prop (carry a uuid). We record
	# the matching JSON object's identity for it (never recreate it) and put the rest under the
	# dyingstarNetwork marker. No uuid on the root -> refuse: this scene is not a server prop.
	var root_uuid := _node_uuid(scene_root)
	if root_uuid == "":
		return {"ok": false, "error":
			"The scene root has no uuid. Open the scene of a server prop (its root must carry a uuid) before importing."}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "error": "Cannot read %s" % path}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_ARRAY:
		return {"ok": false, "error": "JSON root must be an array of objects."}

	# Every imported prop lives under one marker node, so the designer sees what gets serialized.
	var marker := _get_or_create_marker(scene_root)
	# The root's children resolve to the marker; the root's uuid maps there for parent lookups.
	var by_uuid: Dictionary = {root_uuid: marker}
	var created: Array = []  # [{node, parent_id}]
	var counts: Dictionary = {}  # object_type -> instantiated count (diagnostic)
	var skipped := 0
	var matched_root := false
	var root_data: Dictionary = {}  # the JSON object_data of the scene root (for the server-position note)
	for entry in parsed:
		var u: String = str(entry["object_uuid"]) if entry.get("object_uuid") != null else ""
		var t := str(entry.get("object_type", ""))
		if u != "" and u == root_uuid:
			_apply_identity(scene_root, entry)  # root already exists: record its identity, do not recreate
			matched_root = true
			root_data = entry.get("object_data", {})
			continue
		var node := _instantiate(entry)
		if node == null:
			skipped += 1
			push_warning("ServerProps import: could not instantiate a '%s' (scene missing?)" % t)
			continue
		counts[t] = int(counts.get(t, 0)) + 1
		created.append({"node": node, "parent_id": str(entry.get("object_data", {}).get("parent_id", ""))})
		if u != "":
			by_uuid[u] = node

	# Parent each node under its parent prop (by uuid); default under the marker for top-level
	# objects or parents that live elsewhere (e.g. another planet not in this JSON).
	for item in created:
		var node: Node = item["node"]
		var parent: Node = by_uuid.get(item["parent_id"], marker)
		# force_readable_name = true so duplicate scenes get "Name2"… not "@RigidBody3D@123".
		parent.add_child(node, true)
		# Own them so they show in the Scene dock and can be edited — and carry NO metadata (identity
		# is in the session table), so saving the scene never crashes on them.
		node.owner = scene_root
	return {"ok": true, "count": created.size(), "root_node": marker,
		"by_type": counts, "skipped": skipped, "matched_root": matched_root,
		"root_uuid": root_uuid,
		"server_position": root_data.get("position", null),
		"server_parent_id": str(root_data.get("parent_id", ""))}

## Record an EXISTING node's identity (the scene root) without recreating it.
static func _apply_identity(node: Node, entry: Dictionary) -> void:
	var od: Dictionary = entry.get("object_data", {})
	_assign_uuid(node, entry)
	# Not applying position/rotation to the scene root: a Godot scene is edited at the origin; the
	# JSON position is only the SERVER spawn distance, kept in the session table and re-emitted.
	if node.has_method("server_import_data"):
		node.server_import_data(od)
	_record(node, entry)

static func _instantiate(entry: Dictionary) -> Node:
	var od: Dictionary = entry.get("object_data", {})
	var scenename: String = str(od.get("scenename", ""))
	if scenename == "":
		return null
	var packed := load("res://" + scenename) as PackedScene
	if packed == null:
		push_warning("ServerProps import: scene not found: %s" % scenename)
		return null
	var node := packed.instantiate()
	if od.has("name"):
		node.name = str(od["name"])
	_assign_uuid(node, entry)
	if node is Node3D:
		if od.has("position"):
			node.position = _to_v3(od["position"])
		if od.has("rotation"):
			node.rotation = _to_v3(od["rotation"])
	if node.has_method("server_import_data"):
		node.server_import_data(od)
	_record(node, entry)
	return node

## Write an imported uuid onto whichever node actually holds it: the body, else its PropSync. Both
## are silently skipped when the editor only gave the script a placeholder instance (no readable
## `uuid`) — the session table carries the identity in that case, which is the normal editor path.
static func _assign_uuid(node: Node, entry: Dictionary) -> void:
	if entry.get("object_uuid") == null:
		return
	var u := str(entry["object_uuid"])
	if node.get("uuid") != null:
		node.set("uuid", u)
		return
	var sync := _prop_sync(node)
	if sync != null and sync.get("uuid") != null:
		sync.set("uuid", u)

## Store a node's identity (type, uuid, original object_data) in the session table — see _identity.
static func _record(node: Node, entry: Dictionary) -> void:
	_identity[node.get_instance_id()] = {
		"type": str(entry.get("object_type", "")),
		"uuid": str(entry["object_uuid"]) if entry.get("object_uuid") != null else "",
		"data": entry.get("object_data", {}),
	}

# ── Clear ───────────────────────────────────────────────────────────────────

static func clear(scene_root: Node) -> Dictionary:
	if scene_root == null:
		return {"ok": false, "error": "Open a scene first."}
	var markers: Array = []
	_find_markers(scene_root, markers)
	var n := 0
	for m in markers:
		n += m.get_child_count()
		m.get_parent().remove_child(m)
		m.queue_free()
	_identity.clear()
	if markers.is_empty():
		return {"ok": false, "error": "No '%s' node found in the scene." % NETWORK_NODE_NAME}
	return {"ok": true, "count": n}

# ── Helpers ──────────────────────────────────────────────────────────────────

## The dyingstarNetwork grouping node (or a legacy ServerPropsRoot) that holds the imported props.
static func _is_marker(node: Node) -> bool:
	return node.name == NETWORK_NODE_NAME or node is ServerPropsRoot

static func _find_marker(scene_root: Node) -> Node:
	var found: Array = []
	_find_markers(scene_root, found)
	return found[0] if not found.is_empty() else null

static func _find_markers(node: Node, out: Array) -> void:
	if node == null:
		return
	for c in node.get_children():
		if _is_marker(c):
			out.append(c)
		else:
			_find_markers(c, out)

static func _get_or_create_marker(scene_root: Node) -> Node:
	var existing := _find_marker(scene_root)
	if existing != null:
		return existing
	var marker := ServerPropsRoot.new()
	marker.name = NETWORK_NODE_NAME
	scene_root.add_child(marker)
	marker.owner = scene_root
	return marker

## The PropSync component a prop carries as a child, or null. Reached by NAME (PropSync.of does the
## same) so it also resolves on nodes the editor gave a placeholder script instance.
static func _prop_sync(node: Node) -> Node:
	return node.get_node_or_null(NodePath(PROP_SYNC_NODE_NAME))

## Is this node a prop's networking component rather than a prop? It carries an @export `type_name`,
## so without this check the exporter would mistake it for the prop and drop the real body.
static func _is_prop_sync(node: Node) -> bool:
	return node.name == PROP_SYNC_NODE_NAME or node is PropSync

## A prop is a node we recorded on import, one carrying a PropSync component, or a legacy prop whose
## own `type_name` is readable (only @export/@tool vars are, outside of a running game).
static func _is_prop(node: Node) -> bool:
	if _identity.has(node.get_instance_id()):
		return true
	if _is_prop_sync(node):
		return false
	return _prop_sync(node) != null or node.get("type_name") != null

static func _has_prop_descendant(node: Node) -> bool:
	for c in node.get_children():
		if _is_prop(c) or _has_prop_descendant(c):
			return true
	return false

## object_type, from the recorded identity (preferred), the PropSync component, or a legacy
## `type_name` on the body itself.
static func _prop_type(node: Node) -> String:
	var e: Dictionary = _identity.get(node.get_instance_id(), {})
	if e.has("type") and str(e["type"]) != "":
		return str(e["type"])
	var sync := _prop_sync(node)
	if sync != null and sync.get("type_name") != null:
		return str(sync.get("type_name"))
	return str(node.get("type_name")) if node.get("type_name") != null else ""

## object_uuid, from the recorded identity (preferred), the body's own `uuid`, or its PropSync's.
static func _prop_uuid(node: Node) -> String:
	var e: Dictionary = _identity.get(node.get_instance_id(), {})
	if e.has("uuid") and str(e["uuid"]) != "":
		return str(e["uuid"])
	var own := _node_uuid(node)
	if own != "":
		return own
	var sync := _prop_sync(node)
	return _node_uuid(sync) if sync != null else ""

## The original object_data recorded for a node (for fidelity), or {} if none.
static func _stored_data(node: Node) -> Dictionary:
	var e: Dictionary = _identity.get(node.get_instance_id(), {})
	var d = e.get("data", {})
	return d if typeof(d) == TYPE_DICTIONARY else {}

## A node's readable `uuid` as a String, or "" (works for @export uuid like the scene root's).
static func _node_uuid(node: Node) -> String:
	var v = node.get("uuid")
	return str(v) if v != null else ""

## The scene root's uuid: its recorded uuid (after an import) or its readable @export uuid.
static func _root_uuid_of(node: Node) -> String:
	return _prop_uuid(node)

static func _v3(v: Vector3) -> Dictionary:
	return {"x": snappedf(v.x, 0.001), "y": snappedf(v.y, 0.001), "z": snappedf(v.z, 0.0001)}

static func _to_v3(d) -> Vector3:
	return Vector3(float(d.get("x", 0.0)), float(d.get("y", 0.0)), float(d.get("z", 0.0)))

# ── Network definitions (from horizonserver <type>_def.json, cached by the editor plugin) ─────

## {type: [property names]}. Empty until the plugin runs "Update network definitions".
static func load_network_defs() -> Dictionary:
	if not FileAccess.file_exists(DEFS_CACHE):
		return {}
	var f := FileAccess.open(DEFS_CACHE, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

static func has_network_defs() -> bool:
	return not load_network_defs().is_empty()

## Strip each object's object_data down to the properties its type's definition allows. Unknown
## types are left untouched (better to over-export than to silently drop something).
static func _filter_by_defs(objects: Array, defs: Dictionary) -> void:
	for obj in objects:
		var t := str(obj.get("object_type", ""))
		if not defs.has(t):
			continue
		var allowed: Array = defs[t]
		var od: Dictionary = obj.get("object_data", {})
		var filtered: Dictionary = {}
		for k in od:
			if allowed.has(k):
				filtered[k] = od[k]
		obj["object_data"] = filtered
