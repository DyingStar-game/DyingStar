extends Area3D


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	if GameOrchestrator.is_server():
		if not body_entered.is_connected(_on_body_entered_exited):
			body_entered.connect(_on_body_entered_exited.bind("entered"))
		if not body_exited.is_connected(_on_body_entered_exited):
			body_exited.connect(_on_body_entered_exited.bind("exited"))


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass



## WARNING Passer par une Area ne permet plus de faire réagir le poids à ce qui est réellement en contact :
## Si le joueur saute sur le plateforme, il est toujours dans l'Area, son poids est toujours compté
func _on_body_entered_exited(body: Node3D, action: String) -> void:
	for body_inside in get_overlapping_bodies():
		if body_inside is PhysicsBody3D and "sleeping" in body_inside:
			body_inside.sleeping = false
		
	var platform = get_parent_node_3d() as RigidBody3D
	if platform:
		platform.sleeping = false
