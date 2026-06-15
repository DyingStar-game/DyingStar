class_name RearCamera
extends Camera3D

## Rear-view camera fed onto an in-cab screen — a drop-in, reusable by any vehicle (like Gui3D).
##
## THIS node is a real Camera3D so you can place and frame it in the editor (gizmo + frustum +
## the "Preview" button show exactly what it films). It never renders to the player's view
## (current = false); it is only the pose. A twin Camera3D inside the SubViewport copies that pose
## (and fov) and renders the feed, which is shown on the `screen` mesh.
##
## How a vehicle uses it (no code):
## 1. Instance rear_camera.tscn under the vehicle.
## 2. Place/aim THIS camera in the editor at the back, looking behind (use Preview to frame it).
## 3. Set `screen` to the MeshInstance3D that displays the feed (e.g. the cab "Recul" screen).
##
## Purely visual: it only runs on clients, never on the headless game server.

## The cab surface that shows the camera feed (its material_override is replaced by the feed).
@export var screen: MeshInstance3D
## Render resolution of the feed. Keep it small — this is a second full 3D render every frame.
@export var resolution: Vector2i = Vector2i(320, 200)
## Flip the feed left/right. false = a reversing camera (true view); true = a real mirror (side
## mirror / rear-view mirror, which reverses left and right).
@export var mirror: bool = false

@onready var _viewport: SubViewport = $SubViewport
@onready var _camera: Camera3D = $SubViewport/Camera3D

func _ready() -> void:
	if OS.has_feature("dedicated_server"):
		return  # the headless server renders nothing
	current = false  # this camera is only the placement/preview pose, never the player's view
	_viewport.size = resolution
	_viewport.world_3d = get_world_3d()  # render the SAME world, not an empty SubViewport world
	_camera.current = true
	_camera.fov = fov
	if screen != null:
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = _viewport.get_texture()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED  # show the feed as-is, unlit
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # visible on both faces (avoid wrong-side blank)
		if mirror:
			# Reverse left/right within the quad's 0..1 UVs, like a real mirror.
			mat.uv1_scale = Vector3(-1.0, 1.0, 1.0)
			mat.uv1_offset = Vector3(1.0, 0.0, 0.0)
		screen.material_override = mat

func _process(_delta: float) -> void:
	if OS.has_feature("dedicated_server"):
		return
	# Mirror this (placeable) camera's pose + lens into the SubViewport's renderer.
	_camera.global_transform = global_transform
	_camera.fov = fov
