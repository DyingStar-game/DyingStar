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
## mean states, so a hover borrowing either would read as something it is not. A DARK band: the page
## stands on a black veil, and the white at 7 % it was could not be seen on it at all.
const HOVER_COLOR : Color = Color(0.0, 0.0, 0.0, 0.6)
## A value in its healthy range (FPS, TPS), and one that is not — or a warning to be seen at once.
const GOOD_COLOR : Color = Color(0.45, 0.9, 0.45)
const ALERT_COLOR : Color = Color(1.0, 0.3, 0.3)
## Between the two: playable, not comfortable (30-60 FPS, say).
const FAIR_COLOR : Color = Color(1.0, 0.82, 0.3)

## The settings lines' caption size, small as in SQUAD so a page shows its options at a glance
## (settings_label.tres says the same for the lines written in scenes). Section headings stand one
## step above it (SettingsRowFactory.header); the controls one below (settings_theme.tres, 14).
const FONT_SIZE : int = 15
## The rule under a section heading, which the heading's amber modulate tints.
const HEADER_RULE : Color = Color(1.0, 1.0, 1.0, 0.45)
