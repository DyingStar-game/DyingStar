class_name DebugPoll
extends RefCounted
## The refresh of a debug panel that POLLS its value (fps, memory, altitude…), in one place.
##
## Each panel used to loop `while visible: await create_timer(...)`, which gave three defects:
## - the first value came one period AFTER the panel was shown, so a panel shown for one frame (the
##   F8 bug-report capture) read its placeholder, "Soon™";
## - hiding then showing again started a second loop while the first was still waiting, and every
##   toggle of Alt + ² stacked one more;
## - a loop cannot be stopped from outside.
## A Timer child does the waiting instead, stopped while the panel is hidden, and showing the panel
## refreshes it AT ONCE.


## Give [param panel] its timer (every [param seconds], calling [param refresh]) and start hidden.
## Call from the panel's _ready.
static func attach(panel: CanvasItem, seconds: float, refresh: Callable) -> Timer:
	panel.visible = false
	var timer := Timer.new()
	timer.wait_time = seconds
	timer.timeout.connect(refresh)
	panel.add_child(timer)
	return timer


## Show or hide [param panel]. Shown, its value is refreshed now, then every period; hidden, it
## costs nothing.
static func set_shown(panel: CanvasItem, timer: Timer, shown: bool, refresh: Callable) -> void:
	panel.visible = shown
	if shown:
		refresh.call()
		timer.start()
	else:
		timer.stop()
