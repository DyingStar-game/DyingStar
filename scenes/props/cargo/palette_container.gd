extends GenericProp

var content = {}

func client_channel_data_update(data: Dictionary) -> void:
	super.client_channel_data_update(data)
	
	if "content" in data:
		content = data["content"]
