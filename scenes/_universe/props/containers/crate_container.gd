extends GenericProp

var content = {}

func _ready() -> void:
	super._ready()
	# A crate is a physical product: on the server let it fall and roll on the belt,
	# and replicate that motion to clients. The generic create path disables
	# physics_process to keep props static, so we re-enable it here.
	if GameOrchestrator.is_server():
		set_physics_process(true)

func client_channel_data_update(data: Dictionary) -> void:
	super.client_channel_data_update(data)

	if "content" in data:
		content = data["content"]
