@tool
extends EditorPlugin
## Adds the Nova dock (right side). See docs/NOVA.md.

const DockScript := preload("res://addons/nova/nova_dock.gd")
const Debugger := preload("res://addons/nova/nova_debugger.gd")

var _dock: Control
var _debugger := Debugger.new()


func _enter_tree() -> void:
	add_debugger_plugin(_debugger)
	_dock = DockScript.new()
	_dock.name = "Nova"
	_dock.game = _debugger
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)
	var probe := OS.get_environment("NOVA_PROBE")  # a measuring script to run in the editor, for tests
	if probe != "":
		add_child((load(probe) as GDScript).new())


func _exit_tree() -> void:
	remove_debugger_plugin(_debugger)
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
