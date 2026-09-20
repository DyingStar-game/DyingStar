@tool
extends Node3D


@export_range(0.0, 360.0, 0.1, "suffix:°") var pivot_base_rotation: float = 0.0:
	set(value):
		if value != pivot_base_rotation:
			pivot_base_rotation = value
			
			var pivot_base: Node3D = get_node_or_null("%Kiosk Pivot Base Arm 01")
			
			if pivot_base:
				pivot_base.rotation.y = deg_to_rad(-pivot_base_rotation)

@export_range(0.0, 20.0, 0.1, "suffix:°") var pivot_arm01_z_rotation: float = 0.0:
	set(value):
		if value != pivot_arm01_z_rotation:
			pivot_arm01_z_rotation = value
			
			var pivot_arm01_z: Node3D = get_node_or_null("%Kiosk Arm 01")
			var pivot_z_arm01_arm02: Node3D = get_node_or_null("%Kiosk Pivot Z Arm 01 Arm 02")
			
			if pivot_arm01_z and pivot_z_arm01_arm02:
				pivot_arm01_z.rotation.z = deg_to_rad(-pivot_arm01_z_rotation)
				pivot_z_arm01_arm02.rotation.z = deg_to_rad(pivot_arm01_z_rotation)

@export_range(0.0, 360.0, 0.1, "suffix:°") var pivot_arm02_y_rotation: float = 0.0:
	set(value):
		if value != pivot_arm02_y_rotation:
			pivot_arm02_y_rotation = value
			
			var pivot_y_arm01_arm02: Node3D = get_node_or_null("%Kiosk Pivot Y Arm 01 Arm 02")
			
			if pivot_y_arm01_arm02:
				pivot_y_arm01_arm02.rotation.y = deg_to_rad(-pivot_arm02_y_rotation)

@export_range(0.0, 20.0, 0.1, "suffix:°") var pivot_arm02_z_rotation: float = 0.0:
	set(value):
		if value != pivot_arm02_z_rotation:
			pivot_arm02_z_rotation = value
			
			var pivot_arm02_z: Node3D = get_node_or_null("%Kiosk Arm 02")
			
			if pivot_arm02_z:
				pivot_arm02_z.rotation.z = deg_to_rad(pivot_arm02_z_rotation)

@export_range(-20.0, 20.0, 0.1, "suffix:°") var pivot_arm02_balljoint_z_rotation: float = 0.0:
	set(value):
		if value != pivot_arm02_balljoint_z_rotation:
			pivot_arm02_balljoint_z_rotation = value
			
			var pivot_z_arm02_balljoint: Node3D = get_node_or_null("%Kiosk Z Pivot Arm 02 BallJoint")
			
			if pivot_z_arm02_balljoint:
				pivot_z_arm02_balljoint.rotation.z = deg_to_rad(pivot_arm02_balljoint_z_rotation)

@export_range(0.0, 180.0, 0.1, "suffix:°") var pivot_balljoint_y_rotation: float = 0.0:
	set(value):
		if value != pivot_balljoint_y_rotation:
			pivot_balljoint_y_rotation = value
			
			var pivot_y_ball_joint: Node3D = get_node_or_null("%Kiosk Ball Joint")
			
			if pivot_y_ball_joint:
				pivot_y_ball_joint.rotation.y = deg_to_rad(pivot_balljoint_y_rotation)

@export var ball_joint_rotation: Vector2 = Vector2.ZERO:
	set(value):
		const MIN_ROTATION_X: float = -20.0
		const MAX_ROTATION_X: float = 45.0
		const MIN_ROTATION_Z: float = -90.0
		const MAX_ROTATION_Z: float = 90.0
		
		var clamped_value: Vector2 = Vector2(
			clamp(value.x, MIN_ROTATION_X, MAX_ROTATION_X),
			clamp(value.y, MIN_ROTATION_Z, MAX_ROTATION_Z)
		)
		
		if clamped_value != ball_joint_rotation:
		
			ball_joint_rotation = clamped_value
			
			var balljoint_screen: Node3D = get_node_or_null("%Kiosk Tablet")
			
			if balljoint_screen:
				balljoint_screen.rotation.x = deg_to_rad(-ball_joint_rotation.x)
				balljoint_screen.rotation.z = deg_to_rad(ball_joint_rotation.y)


@export var screen_display_viewport: SubViewport:
	set(value):
		if value != screen_display_viewport:
			screen_display_viewport = value
			
			var screen_display: StaticBody3D = get_node_or_null("%Screen Display") as StaticBody3D
			if screen_display:
				#screen_display.screen_display_viewport = screen_display_viewport
				if "node_viewport" in screen_display:
					screen_display.node_viewport = screen_display_viewport


@export var screen_interaction_area: Area3D:
	set(value):
		if value != screen_interaction_area:
			screen_interaction_area = value
