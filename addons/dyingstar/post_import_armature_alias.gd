@tool
extends EditorScenePostImport

## Renames a character glTF's armature node to the name the shared animation library expects.
##
## An AnimationPlayer resolves a bone track by NODE PATH ("<armature>/<skeleton>:<bone>"), so two rigs
## can only share one animation library if their armature node carries the same name. Blender names that
## node after whatever the artist called the object ("test1", "man_ddurieux", ...), which differs per
## export and would silently break every track.
##
## Retargeting (Import dock > Skeleton3D > Retarget) already unifies the BONE names and the rest pose;
## this only unifies the last piece, the node name. Attach it through the Import Script field.

const ARMATURE_NAME := "Armature"


func _post_import(scene: Node) -> Object:
	var skeleton: Skeleton3D = _find_skeleton(scene)
	if skeleton == null:
		push_warning("[DyingStar] %s: no Skeleton3D found, armature not renamed." % get_source_file().get_file())
		return scene

	var armature: Node = skeleton.get_parent()
	if armature == null or armature == scene:
		return scene  # the skeleton already hangs from the scene root: no armature node to rename
	if armature.name == ARMATURE_NAME:
		return scene

	var was: String = String(armature.name)
	armature.name = ARMATURE_NAME
	print("[DyingStar] %s: armature '%s' renamed to '%s'." % [get_source_file().get_file(), was, ARMATURE_NAME])
	return scene


## The imported scene holds exactly one skeleton for a character rig; find it by TYPE, never by name
## (retargeting renames the node to "GeneralSkeleton").
func _find_skeleton(scene: Node) -> Skeleton3D:
	var found: Array[Node] = scene.find_children("*", "Skeleton3D", true, false)
	if found.is_empty():
		return null
	return found[0] as Skeleton3D
