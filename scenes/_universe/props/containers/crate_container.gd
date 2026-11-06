extends GenericProp

## A hauling crate. Its `content` (see CrateContent) is what it holds: shown on its e-ink plate, and
## weighed into its body mass so a crate of ore handles heavier than an empty one.

## Body mass of the empty crate (kg); the content's game mass adds to it.
@export var empty_mass_kg := 50.0

var content = {}


func _ready() -> void:
	super._ready()
	# A crate is a physical product: on the server let it fall and roll on the belt,
	# and replicate that motion to clients. The generic create path disables
	# physics_process to keep props static, so we re-enable it here.
	if GameOrchestrator.is_server():
		set_physics_process(true)
	_apply_content()


## PropSync applies the replicated transform, then calls this with the full payload so we can pick up
## our own (non-transform) fields.
func apply_prop_data(data: Dictionary) -> void:
	if "content" in data and data["content"] is Dictionary:
		content = data["content"]
		_apply_content()


func _apply_content() -> void:
	if not is_inside_tree():
		return
	mass = empty_mass_kg + float(content.get("mass_kg", 0.0))
	var plate := get_node_or_null("Plate") as CratePlate
	if plate != null:
		plate.show_content(content)
