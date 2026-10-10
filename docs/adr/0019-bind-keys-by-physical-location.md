# 0019. Bind every gameplay key as an action, by physical location

- **Status:** Accepted
- **Date:** 2025-08-02 · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** The_Moye, WarpZone
- **Evidence:** 6a41d20f, bd00a95c, 83d1490f, dced5f65, b2f55eda, cca20432, f33eec55, c9fa3036,
  2686e4ca, ba8b1f1a

## Context

The game is designed on AZERTY (ZQSD to move, W to go prone) and played on every layout. A raw
keycode read in a script never shows in Settings > Controls. The HUD mute buttons' N and M
shortcuts were served before the focused control, so neither letter could be typed in a text field.

## Decision

- Every player control is an InputMap action, read through the action, never a `KEY_*` poll.
- Defaults are bound by `physical_keycode` (ZQSD on AZERTY is WASD on QWERTY). A rebind is captured
  and saved in `user://inputs.map` as a physical key. Labels show what the active layout prints on
  that key (`InputLabel._physical_key_name()`).
- Deliberate exceptions, bound by the letter (`physical_keycode` 0): `toggle_speaker` (N) and
  `toggle_microphone` (M), so M is M everywhere; `toggle_eva` (`$`, a developers' tool); Godot's
  `ui_accept`, `ui_cancel` and arrows. `InputLabel.for_event()` and the F1 keyboard
  (`KeyboardDiagram.physical_of()`) name and place them.
- Action names are identifiers on the wire and in the save file. What a player reads comes from
  `MenuConfig.ACTION_GROUPS`, the one table of families, actions and label keys; F1 reads it too.
- One key, one use. Where bindings differ by modifiers, `InputCombo` gives the press to the one
  naming the most held modifiers; two actions bound alike both fire (torch and head lights on L).

## Consequences

- Must not: poll a raw key for a player control; give a new default a keycode; rename an action
  (a saved remap is then skipped, and the server matches "jump"); leave an action out of
  `ACTION_GROUPS` (it lands in "Other"); test Alt by hand around a shared key.
- Rebinding a letter-bound action in the controls page makes it physical. Known gap: `$` is a
  key of its own on AZERTY but Shift+4 on US QWERTY, so `toggle_eva` likely needs a rebind there.

## Rejected alternatives

- **Raw keycodes in scripts**: invisible in the controls page. **HUD button shortcuts** for N and
  M: they ate those letters in every text field.
- **`interact` beside `action` on F**: removed; consoles answer `action`, first and alone.
- **Alt tested by hand around shared keys**: held for the defaults only (a bare F3 never fired).
- **Renaming an action to explain itself**: names are identifiers; a label table does the job.

## In the code

- `project.godot`: the [input] defaults, physical except the letter-bound exceptions
- `scenes/globals/input_label.gd`: InputLabel.for_event and _physical_key_name
- `scenes/globals/binding_capture.gd`: BindingCapture stores the physical key
- `scenes/globals/input_event_codec.gd`: the text a binding is saved as in inputs.map
- `scenes/globals/input_combo.gd`: InputCombo, the most precise binding wins
- `ui/menu_config/menu_config.gd`: MenuConfig.ACTION_GROUPS
- `ui/controls_help/keyboard_diagram.gd`: KeyboardDiagram.physical_of for the F1 keyboard

## Enforced by

`test/unit/test_binding_capture.gd` (a capture is a physical key),
`test/unit/test_input_event_codec.gd` (physical keys round-trip), `test/unit/test_input_combo.gd`.
Nothing checks that defaults are physical or that the exceptions stay the only ones.
