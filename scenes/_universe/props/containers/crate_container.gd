extends GenericProp

var content = {}

func _ready() -> void:
	super._ready()
	# A crate is a physical product: on the server let it fall and roll on the belt,
	# and replicate that motion to clients. The generic create path disables
	# physics_process to keep props static, so we re-enable it here.
	if GameOrchestrator.is_server():
		set_physics_process(true)

## PropSync applies the replicated transform, then calls this with the full payload so we can pick up
## our own (non-transform) fields. Replaces the old client_channel_data_update override.
func apply_prop_data(data: Dictionary) -> void:
	if "content" in data:
		content = data["content"]
