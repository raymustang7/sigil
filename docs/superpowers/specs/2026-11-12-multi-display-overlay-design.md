# Multi-display hint overlay — design

**Date:** 2026-11-12
**Status:** proposed

## Intent

Hint mode (and Visual mode's match badges) must land on the right element on every connected
display. Today they are correct only on a single-display Mac.

## Root cause (confirmed with logs on a 3-display setup)

`OverlayController` draws all hints in **one** borderless panel sized to the union of every
screen's frame. With "Displays have separate Spaces" on (the macOS default), a window may belong
to only one display. Roughly a second after the panel is ordered front, the window server
reassigns it to one display and **translates its origin by minus that display's origin**
(observed: `(-1366, 0)` → `(-4806, -283)`, exactly minus the laptop display's origin
`(3440, 283)`). The frame size and view bounds are unchanged, so every hint is drawn offset by
that vector, and only the slice overlapping the assigned display is visible. The user sees:
hints on one display only, in the wrong places, with a flicker as the window jumps. The
AX → Cocoa conversion in `Geometry` was verified correct against `CGDisplayBounds` and is not at
fault.

A follow-up probe showed that three panels, each sized exactly to one display's frame, are never
moved by the window server, through show, wait, hide and re-show.

## Goals

- Every hint appears on the display that holds its element, at the right place, on the first
  frame, with no relocation flicker.
- Behaviour is identical for hint mode and Visual-mode badges (both use `OverlayController`).
- Display arrangement changes between activations are picked up automatically.

## Non-goals

- Visual-mode popups, warp and toast still appear on `NSScreen.main`; that is cosmetic and
  tracked as a separate follow-up.
- Supporting "Displays have separate Spaces" **off** specially: per-display panels work in both
  settings, so no branch is needed.
- Handling displays that change *during* one activation (between hotkey and Esc).

## Anti-goals

- Any design that shows hints on fewer displays than the user can see (e.g. only the frontmost
  app's display). Seeing an element and being able to type its hint is the whole point.
- Compensating for the window-server move after the fact: it keeps the flicker and still draws
  on one display only.

## Constraints

- Keep the `OverlayController` public surface (`show(boxes:geometry:typedPrefix:)`,
  `updatePrefix(_:boxes:geometry:)`, `hide()`) so `HintModeController` and
  `VisualModeController` need no changes.
- Hint labels remain globally unique across all displays (typing is global).
- Panels keep the existing flags: borderless, non-activating, click-through, `.statusBar`
  level, `.canJoinAllSpaces`, `.stationary`, `.fullScreenAuxiliary`, `.ignoresCycle`.
- No new dependencies; Swift Package stays a single executable target.

## Approaches considered

| | Approach | Trade-off | |
|---|---|---|---|
| **A** | One panel per display, cached by display ID, reused across activations; panels for vanished displays are closed, new displays get one on the next activation. | A little bookkeeping; warm windows show instantly. | **Chosen** |
| B | One panel per display, created on every `show` and destroyed on `hide`. | Zero cache state, but window creation on every hotkey press adds latency and slight visual inconsistency. | Dropped |
| C | A, plus rebuilding panels on the screen-parameters notification. | Buys nothing: the geometry snapshot at activation already reflects the current layout. | Dropped |

Also rejected early: confining hints to the frontmost window's display (anti-goal), and a
single window that re-offsets itself after the move (anti-goal).

## Design (approach A)

**`Geometry`** gains a `screens: [ScreenInfo]` list captured in `snapshot()`, where
`ScreenInfo` holds the display ID (`NSScreenNumber` device description key), the Cocoa frame
and the AX-space frame. The existing `primaryHeight`, `unionCocoaFrame`, `axBounds` and
`cocoaGlobalRect(fromAX:)` are unchanged. A pure helper
`screen(forCocoaPoint:)` returns the screen whose Cocoa frame contains a point, else `nil`.

**Routing.** A `HintBox` is assigned to the screen containing its label anchor, the element's
top-left corner in Cocoa space (`cocoaRect.minX`, `cocoaRect.maxY`). If no screen contains that
point (element partly off every display), fall back to the screen with the largest intersection
with `cocoaRect`; if there is none, the box is dropped. Routing is a pure function on
`Geometry` + `[HintBox]` returning `[displayID: [HintBox]]`, so it can be unit-tested without
AppKit windows.

**`OverlayController`** keeps `[CGDirectDisplayID: (NSPanel, OverlayView)]`. On `show`:
1. Route boxes by screen.
2. For each screen in the snapshot: get or create its panel, set its frame to the screen's
   Cocoa frame, set the view's `originOffset` to that frame's origin, give it that screen's
   boxes (possibly empty) and order it front. Panels whose display is not in the snapshot are
   ordered out and removed from the cache.
3. `updatePrefix` forwards the prefix to every cached view (each already holds its own boxes).
4. `hide` orders out every panel.

**`OverlayView`** is unchanged: it already draws in view-local space using `originOffset`, and
its edge clamp now keeps a label inside its own display, which is the desired behaviour.

## Left to the builder

- Exact shape of the routing helper and where it lives (`Geometry` or a small
  `HintRouter`), as long as it is a pure function with a unit test.
- Whether to add a `Tests/SigilTests` target now (recommended, for the routing test) or keep
  the routing test as a throwaway script if adding XCTest to the package is unwelcome.

## Verification

- Unit test: routing on the recorded 3-display layout (ultrawide at origin, laptop at
  `(3440, 283)`, Dell at `(-1366, 168)`) sends a laptop-anchored box to the laptop display,
  a straddling box to the display holding its top-left corner, and an off-screen box to the
  largest-overlap display.
- Manual: on the 3-display setup, press Ctrl+Space with windows on all three displays; hints
  appear on all three, on the right elements, with no flicker. Temporary `diag` logging of each
  panel's frame after `orderFront` and 1.5 s later shows no move. Repeat after unplugging one
  display. Repeat in Visual mode with a match on a non-main display.
