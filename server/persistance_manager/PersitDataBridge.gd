class_name PersitDataBridge
extends Node

static var persist_callback: Dictionary[String, Callable] = {}

static var wait_client_ready: Array[Callable] = []

static func setup_persistence_manager(calback: Callable):
	if calback.is_null():
		printerr("callable is null !!")
	if OS.has_feature("dedicated_server"):
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
			print("⏳ Waiting signal ClientReady...")
			if not pm.ClientReady.is_connected(_on_client_ready):
				pm.ClientReady.connect(_on_client_ready)
			wait_client_ready.push_back(calback)
	else :
		print("only dev for the server")

# ============ EVENT HANDLERS ============
static func _on_client_ready():
	print("🚀 Signal ClientReady !")
	while wait_client_ready.size() > 0:
		var calback = wait_client_ready.pop_back()
		if !calback.is_null():
			calback.call()

static func _on_save_completed(success: bool, uid: String, error_message: String, request_id: String):
	print("💾 Save completed - RequestID: ", request_id)
	if success:
		if uid == "":
			print("✅Object Updatated ")
		else :
			print("✅Object save with UID: ", uid)
		if persist_callback.has(request_id):
			persist_callback[request_id].call(uid)
			persist_callback.erase(request_id)
		else :
			printerr("no callback for this request id ")
	else:
		printerr("❌ Failed save: ", error_message)

static func _on_delete_completed(success: bool, error_message: String, request_id: String):
	print("🗑️ Delete completed - RequestID: ", request_id)
	if success:
		print("✅ Objet deleted succès")
		if persist_callback.has(request_id):
			persist_callback[request_id].call()
			persist_callback.erase(request_id)
		else :
			printerr("no callback for this request id ")
	else:
		printerr("❌ Failed delete: ", error_message)

static func _on_query_completed(success: bool, json_data: String, error_message: String, request_id: String):
	print("🔍 Query completed - RequestID: ", request_id)
	if success:
		print("✅ Requête Success")
		if persist_callback.has(request_id):
			persist_callback[request_id].call(json_data)
			persist_callback.erase(request_id)
		else :
			printerr("no callback for this request id ")
	else:
		printerr("❌ Échec requête: ", error_message)

static func _on_find_by_id_completed(success: bool, json_data: String, error_message: String, request_id: String):
	print("🎯 FindById completed - RequestID: ", request_id)
	if success:
		print("✅ Serach By ID success")
		if persist_callback.has(request_id):
			persist_callback[request_id].call(json_data)
			persist_callback.erase(request_id)
		else :
			printerr("no callback for this request id ")
	else:
		printerr("❌ Échec recherche: ", error_message)



# ============ function for external use ============
static func save_data(data: DataObject,  calback: Callable):
	var pm = PersistanceManager
	if pm and pm.IsReady:
		var rid = pm.StartSaveAsync(data.serialize())
		persist_callback[rid]=calback
	else:
		printerr("❌ PersistanceManager is not ready for save_data")


static func background_save_data(data: DataObject,  priority: int):
	var pm = PersistanceManager
	if pm and pm.IsReady:
		pm.BackgroundSaveObjAsync(data.serialize(),priority)
	else:
		printerr("❌ PersistanceManager is not ready for save_data")

static func delete_data(uid: String, calback: Callable):
	if uid == "":
		print("❌ not uid")
		return

	var pm = PersistanceManager
	if pm and pm.IsReady:
		var rid = pm.StartDeleteAsync(uid)
		persist_callback[rid]=calback
	else:
		printerr("❌ PersistanceManager is not ready pour delete_data")

static func background_delete_data(uid: String,  priority: int):
	if uid == "":
		print("❌ not uid")
		return
	var pm = PersistanceManager
	if pm and pm.IsReady:
		pm.BackgroundDeleteObjAsync(uid,priority)
	else:
		printerr("❌ PersistanceManager is not ready for delete_data")

static func find_data_by_id(uid: String,calback: Callable):
	var pm = PersistanceManager
	if pm and pm.IsReady:
		var rid = pm.StartFindByIdAsync(uid)
		persist_callback[rid]=calback
	else:
		printerr("❌ PersistanceManager is not ready find_data_by_id")

static func execute_custom_query(query_string: String,calback: Callable):
	var pm = PersistanceManager
	if pm and pm.IsReady:
		var rid = pm.StartQueryAsync(query_string)
		persist_callback[rid]=calback
	else:
		printerr("❌ PersistanceManager is not ready execute_custom_query")
