extends DataObject

class_name  DataEntity


var parent: PhysicsBody3D # check is parent on arbo 

var interval := 2.0

var last_saved_position :Vector3
var last_saved_rotation :Vector3
var parent_obj_uid: String

func serialize():
	var dict = {
		"uuid": uuid_obj,
		"x": last_saved_position.x,
		"y": last_saved_position.y,
		"z": last_saved_position.z,
		"rx": last_saved_rotation.x,
		"ry": last_saved_rotation.y,
		"rz": last_saved_rotation.z,
		"parent": {
			"uid": parent_obj_uid
		}, 
		"dgraph.type": ["Position","Entity"],
		"type_obj": get_parent().type_name
	}
	if not is_new_object and uid != "":
		dict["uid"] = uid
	return JSON.stringify(dict)

func deserialize(data: Dictionary):
	super.deserialize(data)
	if data.has("x") && data.has("y") && data.has("z"):
		last_saved_position = Vector3(
			data['x'],
			data['y'],
			data['z']
		)
	if data.has("rx") && data.has("ry") && data.has("rz"):
		last_saved_rotation = Vector3(
			data['rx'],data['ry'],data['rz']
		)
	if data.has("parent_uid"):
		parent_obj_uid = data["parent_uid"]
	if parent:
		parent.position = last_saved_position
		parent.rotation = last_saved_rotation
	

func _enter_tree():
	check_parent()

func _ready() -> void:
	super._ready()
	check_parent()
		
func start_loop(): # is depracated
	while true:
		await get_tree().create_timer(interval).timeout  # toutes les 2 secondes
		Backgroud_save()

func Backgroud_save():
	if parent.is_remote == false:
		last_saved_position = parent.position
		last_saved_rotation = parent.rotation
		if not is_new_object and uid != "":
			backgroud_save(1)

func await_parent_save():
	# Attendre que le parent soit sauvé
	while parent_obj_uid.is_empty():
		await get_tree().process_frame
	initialize_and_save()

func initialize_and_save():
	if parent.is_remote == false:
		uuid_obj = uuid.v4()
		last_saved_position = parent.position
		last_saved_rotation = parent.rotation
		saved()

func load_obj(data: Dictionary):
	print("load Data Object")
	is_new_object = false
	deserialize(data)
	#PersitDataBridge.execute_custom_query('''
	#{
	#  entity(func: uid({0})) {
	#	uid
	#	uuid
	# 	type_obj
	#	x
	#	y
	#	z
	#	rx
	#	ry
	#	rz
	# }
	#}'''.format([data["uid"]]),loaded)
	
	
func loaded(result: String):
	print(" Data Entity is loaded")
	var parsed = JSON.parse_string(result)
	if parsed != null:
		deserialize(parsed["entity"][0])

func check_parent():
	parent = get_parent()
	if parent and not (parent is PhysicsBody3D):
		push_error("PersitData is not children of PhysicsBody3D.")

func  _on_client_ready():
	print("🚀 Signal ClientReady Persist Physic Data !")

func _on_parent_ready() -> void:
	if OS.has_feature("dedicated_server"):
		PersitDataBridge.setup_persistence_manager(_on_client_ready)
		if is_new_object:
			last_saved_position = parent.position
			last_saved_rotation = parent.rotation
			if parent.get_parent() != null && parent.get_parent().has_node("DataPlanet"):
				parent_obj_uid = parent.get_parent().get_node("DataPlanet").uid
				print("Parent UID: ", parent_obj_uid)
				if parent_obj_uid.is_empty():
					print("⏳ Waiting for parent to be saved...")
					# Créer un timer ou attendre le signal de sauvegarde du parent
					await_parent_save()
				else:
					initialize_and_save()
	else:
		print ("data entity is instanciate on client ")
