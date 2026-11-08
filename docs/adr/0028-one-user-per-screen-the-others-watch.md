# 0028. One player uses a world screen at a time, and the others watch it

- **Status:** Accepted
- **Date:** 2026-11-07 · **Recorded:** 2026-11-08 · **Updated:** —
- **Deciders:** WarpZone
- **Evidence:** 11a79a5d, a1f4e658 (#480), the teleporter's view (2026-11-08)

## Context

Every client drew its own copy of a world screen and clicked it on its own: two players at a mission
kiosk browsed apart, two at a machine pressed over each other, two at a teleporter each saw their own
lists. Only the final action went to the server, so what one player was doing on a screen was invisible
to the player beside them, and nothing stopped them both acting at once.

## Decision

- A world screen (anything under the ScreenTarget contract) is held by ONE player: the first who acts
  on it, until they step out of `ScreenTarget.USE_RANGE_M` or leave. The server refuses the others'
  actions meanwhile (`ScreenLock.claim`, before `update_screen`).
- The holder's client shares what the screen shows, its view, through the screen contract's channel; the
  server passes it on to the clients around (`ScreenTarget.announce`) and repeats it every
  `ScreenLock.REPEAT_S` for a player who comes later.
- A watched screen does not answer the watcher: no hover, no click, no message that would suggest it
  could be used.
- **Every screen with state of its own on the client implements the view contract** on its UI:
  `view_state() -> Dictionary` (what its user looks at: tab, filters, selection, page, typed fields)
  and `apply_view_state(view)` (show it, rebuilding lists only when what they list changed). Data the
  user fetched with their own identity travels in the view (the kiosk's "In progress" missions): a
  watcher shows the user's, not its own.
- A screen driven by the server's replicated state (a machine, a lift) needs no view: it is locked.

## Consequences

- Two players at a screen see the same page; one acts, the other watches, then takes over.
- Must not: add a screen whose UI keeps its own browsing state without the view contract, nor let a
  watcher's input reach a held screen.
- The view is repeated while a screen is held: keep it small (ids and fields, not whole lists, unless
  they are the user's own data the watcher cannot fetch).

## Rejected alternatives

- Locking without sharing: the watcher saw an idle screen while the user was working.
- A "used by X" message on the watcher's screen: it suggested the screen could be used (playtest
  2026-11-07); the silence of a screen that does not answer says it better.
- Sending the view on change only: a player arriving after the last change saw their own page.

## In the code

- `scenes/interactables/screen_lock.gd`: `claim`, `serve`, `release_away`, `REPEAT_S`, `used_by_other`,
  `view_node`
- `scenes/interactables/screen_target.gd`: `receive` hands lock events to ScreenLock
- `scenes/player/player_client.gd`: `_share_screen_view`, `_used_by_other`
- Views: `mission_kiosk_ui.gd`, `item_dispenser_ui.gd`, `teleporter_ui.gd`

## Enforced by

`test/unit/test_screen_lock.gd`; `test_teleport_grouping.gd::test_a_watcher_sees_the_teleporter_as_its_user_does`.
