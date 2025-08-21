extends Node
class_name PersitDataBridge

static var persistCalback: Dictionary[String, Callable]

static var waitClientReady: Array[Callable]

static func setup_persistence_manager(calback: Callable):
	if OS.has_feature("dedicated_server") || true:
		var pm = PersistanceManager
		if not pm:
			push_error("PersistanceManager is null!")
			return
		# Connect all PersistanceManagerSignal
		if not pm.SaveCompleted.is_connected(_on_save_completed):
			pm.SaveCompleted.connect(_on_save_completed)
		
		if not pm.DeleteCompleted.is_connected(_on_delete_completed):
			pm.DeleteCompleted.connect(_on_delete_completed)
		
		if not pm.QueryCompleted.is_connected(_on_query_completed):
			pm.QueryCompleted.connect(_on_query_completed)
		
		if not pm.FindByIdCompleted.is_connected(_on_find_by_id_completed):
			pm.FindByIdCompleted.connect(_on_find_by_id_completed)
		
		# Démarrer les opérations si le manager est prêt
		if pm.IsReady:
			print("✅ Client Alredy start")
			calback.call()
		else:
			print("⏳ En attente du signal ClientReady...")
			if not pm.ClientReady.is_connected(_on_client_ready):
				pm.ClientReady.connect(_on_client_ready)
			waitClientReady.push_back(calback)
	else :
		print("only dev for the server")

# ============ EVENT HANDLERS ============
static func _on_client_ready():
	print("🚀 Signal ClientReady !")
	while waitClientReady.size() > 0:
		var calback = waitClientReady.pop_back()
		calback.call()

static func _on_save_completed(success: bool, uid: String, error_message: String, request_id: String):
	print("💾 Save completed - RequestID: ", request_id)
	if success:
		print("✅Object save with UID: ", uid)
		persistCalback[request_id].call(uid)
		persistCalback.erase(request_id)
	else:
		printerr("❌ Failed save: ", error_message)

static func _on_delete_completed(success: bool, error_message: String, request_id: String):
	print("🗑️ Delete completed - RequestID: ", request_id)
	if success:
		print("✅ Objet deleted succès")
		persistCalback[request_id].call()
		persistCalback.erase(request_id)
	else:
		printerr("❌ Failed delete: ", error_message)

static func _on_query_completed(success: bool, json_data: String, error_message: String, request_id: String):
	print("🔍 Query completed - RequestID: ", request_id)
	if success:
		print("✅ Requête Success")
		persistCalback[request_id].call(json_data)
		persistCalback.erase(request_id)
	else:
		printerr("❌ Échec requête: ", error_message)

static func _on_find_by_id_completed(success: bool, json_data: String, error_message: String, request_id: String):
	print("🎯 FindById completed - RequestID: ", request_id)
	if success:
		print("✅ Serach By ID success")
		persistCalback[request_id].call(json_data)
		persistCalback.erase(request_id)
	else:
		printerr("❌ Échec recherche: ", error_message)



# ============ function for external use ============
static func save_data(data: DataObject,  calback: Callable):
	var pm = PersistanceManager
	if pm and pm.IsReady:
		var rid = pm.StartSaveAsync(data.serialize())
		print(rid);
		persistCalback[rid]=calback
	else:
		printerr("❌ PersistanceManager is not ready for save_data")

static func delete_data(uid: String, calback: Callable):
	if uid == "":
		print("❌ not uid")
		return
	
	var pm = PersistanceManager
	if pm and pm.IsReady:
		var rid = pm.StartDeleteAsync(uid)
		persistCalback[rid]=calback
	else:
		printerr("❌ PersistanceManager is not ready pour delete_data")

static func find_data_by_id(uid: String,calback: Callable):
	var pm = PersistanceManager
	if pm and pm.IsReady:
		var rid = pm.StartFindByIdAsync(uid)
		persistCalback[rid]=calback
	else:
		printerr("❌ PersistanceManager is not ready find_data_by_id")

static func execute_custom_query(query_string: String,calback: Callable):
	var pm = PersistanceManager
	if pm and pm.IsReady:
		var rid = pm.StartQueryAsync(query_string)
		persistCalback[rid]=calback
	else:
		printerr("❌ PersistanceManager is not ready execute_custom_query")
