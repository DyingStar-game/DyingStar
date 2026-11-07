# 0027. A screen in the world works only when someone can see it

- **Status:** Accepted
- **Date:** 2026-11-07 · **Recorded:** 2026-11-07 · **Updated:** —
- **Deciders:** David Durieux, WarpZone
- **Evidence:** ea22a929 (#479), the hauling crate plate of #478

## Context

A town holds dozens of machine screens, kiosks and crate plates, and their usual state is asleep with
nobody looking. Every sleeping `ScreenAttract` redrew its facet pattern each frame, seen or not: 21 of
them cost about 55 ms a frame in the deferred canvas flush and took a village to 10 fps. Drawing the
pattern as 80 `draw_colored_polygon` calls cost another 2.6 ms a frame per moving screen (a
triangulation and a vertex buffer per facet).

## Decision

- A screen, plate or any canvas drawn into the 3D world animates or redraws **only when the camera is
  near and has it in view**: within a range in metres (`ScreenAttract.ANIMATE_RANGE_M`, 12 m; the crate
  plate 4 m) and `Camera3D.is_position_in_frustum`. Otherwise it stands still, and takes up from where
  it stopped (no jump).
- The visibility check is throttled (`SEEN_CHECK_S`, 0.25 s) and staggered with a random start, so the
  screens of a town do not all ask in the same frame.
- With no camera (the dedicated server) nobody is looking: nothing animates. A screen not in a 3D world
  (a 2D menu) is on show as it is.
- Something static is drawn once: `SubViewport.UPDATE_ONCE`, re-rendered only when its content changes
  (the crate plate).
- Many shapes in one `_draw` go to the server as one batch (`RenderingServer.canvas_item_add_triangle_array`),
  not one draw call each.
- A machine's server logic runs on a tick (`OreProcessor.SERVER_TICK_S`), not every frame, and
  replicates on change only.

## Consequences

- The cost of screens follows what the player looks at, not how many there are in town.
- Must not: start a `_process` / `queue_redraw` loop on a world screen without the near-and-in-view
  gate, nor redraw an unchanged static face each frame.
- A screen seen from more than its range is frozen: a deliberate trade, the detail is unreadable there.

## Rejected alternatives

- Letting sleeping screens animate everywhere: 55 ms a frame for 21 screens (ea22a929).
- Pausing on distance alone: a screen behind the player kept costing.
- One polygon call per facet: 2.6 ms a frame per moving 8x5 pattern.

## In the code

- `ui/screens/screen_attract.gd`: `ANIMATE_RANGE_M`, `SEEN_CHECK_S`, `_update_seen`
- `ui/screens/facet_pattern.gd`: `paused`, the one triangle array in `_draw`
- `scenes/_universe/props/containers/crate_plate.gd`: drawn once, shown within 4 m
- `scenes/_universe/structures/industrial/mines/ore_processor.gd`: `SERVER_TICK_S`

## Enforced by

`test/unit/test_screen_widgets.gd`: `test_a_sleeping_screen_only_moves_near_the_camera_and_in_its_view`,
`test_a_screen_with_no_camera_stands_still_and_one_not_in_3d_moves`, `test_a_paused_pattern_takes_up_where_it_stopped`.
