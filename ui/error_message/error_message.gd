class_name ErrorMessage

extends CanvasLayer

signal exited

@export var title: String
@export var message: String
@export var exit_button_label: String

@onready var background: ColorRect = $ErrorMessage/Background
@onready var error_container: VBoxContainer = $ErrorMessage/VBox
@onready var title_label: Label = $ErrorMessage/VBox/Panel/VBoxContainer/Title
@onready var message_label: Label = $ErrorMessage/VBox/Panel/VBoxContainer/Message
@onready var exit_btn: Button = $ErrorMessage/VBox/ExitBtn

func _ready() -> void:
	title_label.text = title
	message_label.text = message
	exit_btn.text = exit_button_label

	background.color.a = 0
	error_container.modulate.a = 0
	error_container.scale = Vector2.ONE * 0.4

	show_message()


func show_message(_title: String = "", _message: String = ""):
	if _title != "":
		title_label.text = _title
	if _message != "":
		message_label.text = _message

	show()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var tw = create_tween()
	tw.parallel().tween_property(background, "color:a", 0.9, 0.5).set_trans(Tween.TRANS_CUBIC)
	tw.parallel().tween_property(error_container, "modulate:a", 1, 0.5).set_trans(Tween.TRANS_CUBIC)
	tw.parallel().tween_property(error_container, "scale", Vector2.ONE, 1).set_trans(Tween.TRANS_CUBIC)

func hide_message():
	var tw = create_tween()
	tw.parallel().tween_property(background, "color:a", 0, 0.5).set_trans(Tween.TRANS_CUBIC)
	tw.parallel().tween_property(error_container, "modulate:a", 0, 0.5).set_trans(Tween.TRANS_CUBIC)
	tw.parallel().tween_property(
		error_container, "scale", Vector2.ONE * 0.4, 1
	).set_trans(Tween.TRANS_CUBIC)
	await tw.finished
	hide()

func _on_exit_btn_pressed() -> void:
	exited.emit()
	GameOrchestrator.change_game_state(GameOrchestrator.GameStates.HOME_MENU)
