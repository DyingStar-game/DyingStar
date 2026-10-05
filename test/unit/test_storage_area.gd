extends GutTest
## PadStorageArea: a levelled stretch of ground whose size travels with it, and whose children in a
## layout are spawned in its frame (poi_villages.gd), so they follow it onto its ground.

const AREA := "res://scenes/_universe/structures/industrial/storage/pad_storage_area.tscn"
const POI_VILLAGES := preload("res://scenes/_universe/structures/urban/poi_villages.gd")
const CONTAINER := "res://scenes/_universe/props/containers/container_standard_a_1200x240x240.tscn"


## Checked before the tree: outside the editor TerrainPad reads its Ground box on entering it, then frees it.
func test_its_size_shapes_the_levelled_ground() -> void:
	var area: PadStorageArea = load(AREA).instantiate()
	var ground := area.get_node("TerrainPad/Ground") as CSGBox3D
	var thickness := ground.size.y
	area.size = Vector2(30.0, 8.0)
	assert_eq(Vector2(ground.size.x, ground.size.z), Vector2(30.0, 8.0))
	assert_eq(ground.size.y, thickness, "the top face stays at the ground level")
	area.size = Vector2(0.0, -3.0)
	assert_eq(area.size, Vector2(PadStorageArea.MIN_SIDE_M, PadStorageArea.MIN_SIDE_M), "never a flat-to-nothing area")
	area.free()


## The network data reaches a spawned prop BEFORE it enters the tree (server/server.gd, server/client.gd):
## the flattener must read a box already at the replicated size.
func test_the_replicated_size_applies_before_the_flattener_reads_it() -> void:
	var area: PadStorageArea = load(AREA).instantiate()
	area.apply_prop_data({"size": {"x": 40.0, "y": 6.0}})
	var ground := area.get_node("TerrainPad/Ground") as CSGBox3D
	assert_eq(area.size, Vector2(40.0, 6.0))
	assert_eq(Vector2(ground.size.x, ground.size.z), Vector2(40.0, 6.0))
	area.free()


## The server states the pad of an area it has no node for from its data (server.gd
## _stream_register_pads): the same box as the node's, or the ground gets two records.
func test_the_server_states_the_same_pad_from_the_data() -> void:
	var area: PadStorageArea = load(AREA).instantiate()
	area.apply_prop_data({"size": {"x": 33.0, "y": 7.5}})
	var ground := area.get_node("TerrainPad/Ground") as CSGBox3D
	var box := PadStorageArea.terrain_pad_box({"size": {"x": 33.0, "y": 7.5}})
	assert_eq(box["size"], ground.size)
	assert_eq(box["local"], ground.transform)
	var default_box := PadStorageArea.terrain_pad_box({})
	assert_eq(default_box["size"], Vector3(20.0, 1.0, 12.0), "an area with no size in its data: the scene's")
	area.free()


func test_its_children_find_it_as_their_network_frame() -> void:
	var area: PadStorageArea = load(AREA).instantiate()
	area.uuid = "area-uuid"
	assert_eq(PropSpawn.net_parent_uuid(area), "area-uuid", "a child publishes its pose in the area's frame")
	area.free()


func test_its_definition_replicates_the_size() -> void:
	var def: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://items_def/storage_area_def.json"))
	var props: Array = []
	for channel: Dictionary in def["channels"]:
		props.append_array(channel["properties"])
	for p: String in ["position", "rotation", "parent_id", "scenename", "terrain_settled", "size"]:
		assert_has(props, p)
	var area: Node = load(AREA).instantiate()
	assert_eq(PropSync.of(area).type_name, "storage_area")
	area.free()


## What poi_villages spawns under an item: the props the LAYOUT placed there, not the item's own nodes.
func test_the_village_spawns_what_the_layout_put_under_an_area() -> void:
	var layout := Node3D.new()
	var area: Node = load(AREA).instantiate()
	layout.add_child(area)
	area.owner = layout
	var box: Node = load(CONTAINER).instantiate()
	area.add_child(box)
	box.owner = layout
	assert_true(POI_VILLAGES.is_spawnable(area))
	assert_eq(POI_VILLAGES.layout_children(area, layout), [box] as Array[Node],
			"the container, and not the area's PropSync or TerrainPad")
	layout.free()
