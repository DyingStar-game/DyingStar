class_name WidgetSection
extends OverlaySection
## A section of controls built once: `builder` receives (this section, its content box, the panel's
## row factory) and fills the box. Nodes it needs to keep (a GraphicsOptionsView…) are added under
## the section, so they live and die with it.


var _builder : Callable


func _init(p_title_key: String, builder: Callable, gate: Callable = Callable()) -> void:
	super(p_title_key, gate, 0.0)
	_builder = builder


func _build_content(content: VBoxContainer, factory: SettingsRowFactory) -> void:
	_builder.call(self, content, factory)
