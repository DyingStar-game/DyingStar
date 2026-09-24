class_name SettingsStyle
extends RefCounted
## The few colours the settings pages agree on, in one place.
##
## They were drifting apart already: the "you are here" amber lived in settings_page.gd and the row
## hover in settings_row.gd, with nothing saying they belonged to the same vocabulary. The controls
## page now needs both, which would have made it three copies.

## "You are here": the open category, or the open family of keybindings.
const ACTIVE_COLOR : Color = Color(1.0, 0.84, 0.35)
const INACTIVE_COLOR : Color = Color(1.0, 1.0, 1.0)
## Surface behind the selected tab. The active amber again, kept faint so it reads as a surface
## rather than as text — a solid amber block would shout louder than the label it carries.
const ACTIVE_BG : Color = Color(1.0, 0.84, 0.35, 0.16)
## "The pointer is on this line." Deliberately neutral — amber already means active, and green/red
## mean states, so a hover borrowing either would read as something it is not.
const HOVER_COLOR : Color = Color(1.0, 1.0, 1.0, 0.07)
