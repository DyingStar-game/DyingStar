extends SceneTree

signal scene_changed_custom(new_scene: Node)

const MAX_WAITING_FRAME_COUNT: int = 5

@warning_ignore("native_method_override")
func change_scene_to_packed(packed_scene: PackedScene) -> int:
	var err: int = super.change_scene_to_packed(packed_scene)
	if err == OK:

		var max_frames: int = MAX_WAITING_FRAME_COUNT
		while not self.current_scene and max_frames > 0:
			await self.process_frame
			max_frames -= 1

		var new_current_scene: Node = self.current_scene
		if new_current_scene:
			if new_current_scene.get("is_ready"):
				if not new_current_scene.is_ready:
					await new_current_scene.ready
					emit_signal("scene_changed_custom", new_current_scene)
				else:
					emit_signal("scene_changed_custom", new_current_scene)

	return err

@warning_ignore("native_method_override")
func change_scene_to_file(scene_file: String) -> int:
	var err: int = super.change_scene_to_file(scene_file)
	if err == OK:

		var max_frames: int = MAX_WAITING_FRAME_COUNT
		while not self.current_scene and max_frames > 0:
			await self.process_frame
			max_frames -= 1

		var new_current_scene: Node = self.current_scene
		if new_current_scene:
			if new_current_scene.get("is_ready"):
				if not new_current_scene.is_ready:
					await new_current_scene.ready
					emit_signal("scene_changed_custom_custom", new_current_scene)
				else:
					emit_signal("scene_changed_custom", new_current_scene)

	return err
