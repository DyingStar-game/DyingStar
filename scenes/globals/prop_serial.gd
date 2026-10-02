class_name PropSerial
extends RefCounted
## The serial printed on a networked object: "COMPANY-TYPE-UUID" (ARES-HAUL-8C44B2F9), and the frames
## that show it — every Label3D below the object in the group LABEL_GROUP, whatever its name.
##
## Shared by every body that carries one: the crates and parts (GenericProp, a RigidBody3D) and the
## vehicles' plates (Vehicle, a VehicleBody3D). Neither can inherit from the other, so the rule lives
## here once and each only says which company, type and uuid it has. Nothing travels for it: the uuid
## is already replicated and persisted, the rest is in the scene.

const LABEL_GROUP : StringName = &"prop_id_label"


## The serial of [param uuid] under [param company]-[param type]; "" while there is no uuid yet.
## [param short]: only the uuid's first block, uppercased, to fit a small face (a crate's side, a
## plate). Display only — the identity stays the full uuid.
static func format(company: String, type: String, uuid: String, short: bool) -> String:
	if uuid == "":
		return ""
	return "%s-%s-%s" % [company, type, uuid.split("-")[0].to_upper() if short else uuid]


## Write [param serial] on every id frame under [param root]. An empty serial leaves them as they are
## (the scene's placeholder, in the editor or a bench without a server).
static func fill(root: Node, serial: String) -> void:
	if serial == "":
		return
	for node in root.find_children("*", "Label3D", true, false):
		if node.is_in_group(LABEL_GROUP):
			(node as Label3D).text = serial
