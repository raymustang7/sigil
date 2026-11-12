# Multi-display Hint Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Draw hints through one click-through panel per display so macOS never relocates the overlay and every hint lands on the display that holds its element.

**Architecture:** `Geometry` captures a per-screen list (display ID, Cocoa frame, AX frame) in its snapshot and gains a pure routing function that assigns each `HintBox` to a display. `OverlayController` keeps one cached `NSPanel`/`OverlayView` pair per display ID, sized exactly to that display, and fans `show`/`updatePrefix`/`hide` out to them. Its public API is unchanged so neither mode controller changes.

**Tech Stack:** Swift 6 toolchain in Swift 5 language mode, AppKit, SwiftPM, XCTest (new test target).

**Spec:** `docs/superpowers/specs/2026-11-12-multi-display-overlay-design.md`

## Global Constraints

- `OverlayController` keeps `show(boxes:geometry:typedPrefix:)`, `updatePrefix(_:boxes:geometry:)`, `hide()` with their current signatures.
- Panels keep the existing flags: `.borderless`, `.nonactivatingPanel`, `isFloatingPanel`, non-opaque clear background, no shadow, `ignoresMouseEvents`, level `.statusBar`, collection behaviour `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`.
- Hint labels stay globally unique (label generation is untouched).
- No new dependencies; Package.swift gains only a `testTarget`.
- Routing is a pure function on `Geometry` + `[HintBox]`, unit-tested without windows.

## Review Focus

1. A menu-bar item sits on a display's top edge, so its Cocoa `maxY` equals the display's `maxY`; it must route to that display, not fall through to overlap matching. → Task 1 `testTopEdgeItemRoutesToItsDisplay`.
2. An element whose left edge is exactly on the seam between two side-by-side displays must route deterministically to the display on the right of the seam. → Task 1 `testAnchorOnSeamRoutesToRightDisplay`.
3. A display is unplugged between two activations; its cached panel must be ordered out and dropped, and its hints must not appear anywhere. → Task 1 `testBoxOverlappingNoDisplayIsDropped`; Task 2 manual step 6.
4. Zero screens in the snapshot (display sleep, headless) must show nothing and not crash. → Task 1 `testNoScreensRoutesNothing`; Task 2 guards on empty `screens`.
5. Visual mode calls `show` repeatedly while panels are already visible, with a different box set each time; stale hints from the previous call must not linger on a display that now has none. → Task 2 step 3 (every panel in the snapshot is updated, with an empty list when it has no boxes).

---

### Task 1: Per-screen geometry and hint routing (with test target)

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/Sigil/Geometry.swift`
- Create: `Tests/SigilTests/HintRoutingTests.swift`

**Interfaces:**
- Consumes: `HintBox` from `Sources/Sigil/OverlayView.swift` (`cocoaRect: CGRect`, `label: String`).
- Produces:
  ```swift
  struct ScreenInfo: Equatable {
      let displayID: CGDirectDisplayID
      let cocoaFrame: CGRect
      let axFrame: CGRect
  }
  struct Geometry {
      let primaryHeight: CGFloat
      let unionCocoaFrame: CGRect
      let axBounds: CGRect
      let screens: [ScreenInfo]                       // new; memberwise init stays internal
      static func snapshot() -> Geometry
      func cocoaGlobalRect(fromAX ax: CGRect) -> CGRect
      func screen(containingCocoaAnchor point: CGPoint) -> ScreenInfo?   // new
      func route(_ boxes: [HintBox]) -> [CGDirectDisplayID: [HintBox]]   // new
  }
  ```
  Anchor containment is half-open the way a top-left anchor needs: `minX <= x < maxX` and `minY < y <= maxY`.
  Routing: anchor = `(cocoaRect.minX, cocoaRect.maxY)`; if no screen contains it, the screen with the largest `cocoaRect.intersection(cocoaFrame)` area wins; zero overlap → box dropped. Result dictionary only has keys for displays that received at least one box.

- [ ] **Step 1: Add the test target**

In `Package.swift` add `.testTarget(name: "SigilTests", dependencies: ["Sigil"], path: "Tests/SigilTests")`.

- [ ] **Step 2: Write the failing tests**

`Tests/SigilTests/HintRoutingTests.swift`, `@testable import Sigil`, with the recorded 3-display layout as fixtures:

```swift
let ultrawide = ScreenInfo(displayID: 3, cocoaFrame: CGRect(x: 0, y: 0, width: 3440, height: 1440), axFrame: CGRect(x: 0, y: 0, width: 3440, height: 1440))
let laptop    = ScreenInfo(displayID: 1, cocoaFrame: CGRect(x: 3440, y: 283, width: 1512, height: 982), axFrame: CGRect(x: 3440, y: 175, width: 1512, height: 982))
let dell      = ScreenInfo(displayID: 2, cocoaFrame: CGRect(x: -1366, y: 168, width: 1366, height: 768), axFrame: CGRect(x: -1366, y: 504, width: 1366, height: 768))
let geometry  = Geometry(primaryHeight: 1440, unionCocoaFrame: CGRect(x: -1366, y: 0, width: 6318, height: 1440), axBounds: CGRect(x: -1366, y: 0, width: 6318, height: 1440), screens: [ultrawide, laptop, dell])
```

Tests (each asserts on `geometry.route([box])` unless stated):
- `testLaptopBoxRoutesToLaptop`: box `(3524, 1191, 28, 28)` → key `1` holds label `"AA"`, no other keys.
- `testMainDisplayBoxRoutesToMain`: box `(6, 1334, 34, 34)` → key `3`.
- `testDellBoxRoutesToDell`: box `(-1000, 500, 40, 20)` → key `2`.
- `testTopEdgeItemRoutesToItsDisplay`: box `(100, 1418, 60, 22)` (maxY == 1440) → key `3`.
- `testAnchorOnSeamRoutesToRightDisplay`: box `(3440, 1000, 50, 20)` → key `1`.
- `testStraddlingBoxRoutesByTopLeft`: box `(3400, 1000, 100, 20)` → key `3`.
- `testOffscreenAnchorFallsBackToLargestOverlap`: box `(-1400, 200, 100, 20)` → key `2`.
- `testBoxOverlappingNoDisplayIsDropped`: box `(-2000, 2000, 10, 10)` → empty dictionary.
- `testNoScreensRoutesNothing`: `Geometry(... screens: [])` with the laptop box → empty dictionary.
- `testEveryOnScreenBoxLandsOnExactlyOneDisplay`: the first seven boxes above → summed values count == 7.
- `testSnapshotHasOneEntryPerScreen`: `Geometry.snapshot().screens.count == NSScreen.screens.count` and each `axFrame` equals `cocoaGlobalRect(fromAX:)` round-trip (`cocoaGlobalRect(fromAX: s.axFrame) == s.cocoaFrame`).

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test 2>&1 | tail -20`
Expected: compile errors — `ScreenInfo` undefined, `Geometry` has no member `screens` / `route`.

- [ ] **Step 4: Implement `ScreenInfo`, `screens`, `screen(containingCocoaAnchor:)`, `route(_:)` in `Sources/Sigil/Geometry.swift`**

Display ID: `screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID` (bridge via `NSNumber` `uint32Value` if the direct cast fails). `snapshot()` builds `screens` from the same loop that builds `axUnion`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -20`
Expected: `Executed 11 tests, with 0 failures`.

- [ ] **Step 6: Commit (deferred)**

Commits happen in Task 3 on the user's go-ahead.

---

### Task 2: One panel per display in `OverlayController`

**Files:**
- Modify: `Sources/Sigil/OverlayController.swift` (whole file)
- Modify: `Sources/Sigil/OverlayView.swift` (add one method)

**Interfaces:**
- Consumes: `Geometry.screens`, `Geometry.route(_:)` from Task 1; `OverlayView.update(boxes:originOffset:typedPrefix:)`.
- Produces: unchanged public API. Internal:
  ```swift
  private struct ScreenPanel { let panel: NSPanel; let view: OverlayView }
  private var panels: [CGDirectDisplayID: ScreenPanel]
  private func screenPanel(for screen: ScreenInfo) -> ScreenPanel   // get-or-create, frame set to screen.cocoaFrame
  ```
  `OverlayView` gains `func setTypedPrefix(_ prefix: String)` (keeps current boxes, sets prefix, `needsDisplay = true`).

- [ ] **Step 1: Add `setTypedPrefix(_:)` to `OverlayView`**

- [ ] **Step 2: Rewrite `show(boxes:geometry:typedPrefix:)`**

Route boxes with `geometry.route(boxes)`. For every `ScreenInfo` in `geometry.screens`: get-or-create its `ScreenPanel`, `setFrame(screen.cocoaFrame, display: false)`, resize its view to `cocoaFrame.size`, call `view.update(boxes: routed[id] ?? [], originOffset: screen.cocoaFrame.origin, typedPrefix:)`, then `orderFrontRegardless()`. For every cached display ID **not** in the snapshot: `orderOut(nil)` and remove from `panels`. If `geometry.screens` is empty, hide everything and return.

- [ ] **Step 3: Add one permanent log line to `show`**

`Log.write("overlay: \(geometry.screens.count) displays, \(boxes.count) hints → " + per-display "id:count" list)`. This replaces the temporary diag logging used during investigation and is the manual-verification signal.

- [ ] **Step 4: Rewrite `updatePrefix(_:boxes:geometry:)` and `hide()`**

`updatePrefix` calls `setTypedPrefix` on every cached view (parameters `boxes`/`geometry` are kept for API compatibility and unused). `hide` orders out every cached panel.

- [ ] **Step 5: Move panel construction into `makePanel(frame:) -> ScreenPanel`**

Same flags as today (see Global Constraints), content view `OverlayView(frame: CGRect(origin: .zero, size: frame.size))`.

- [ ] **Step 6: Build, run and verify manually on the 3-display layout**

Run: `ARCHS=arm64 ./scripts/bundle.sh release && pkill -x Sigil; open .build/Sigil.app`
Then, with windows open on all three displays, the user presses Ctrl+Space, waits 2 s, presses Esc, and repeats once; then types a hint on a non-main display.
Expected in `/tmp/sigil.log`: `overlay: 3 displays, N hints → 3:a 1:b 2:c` with all three counts non-zero. Expected on screen: hints on all three displays on the right elements, no flicker or jump, the typed hint activates its element. Then unplug one display and repeat: log shows `2 displays`, no hints on the gone display, no crash.

- [ ] **Step 7: Run the unit tests again**

Run: `swift test 2>&1 | tail -5` — Expected: `0 failures`.

---

### Task 3: Commit

- [ ] **Step 1: On the user's go-ahead, commit design doc, plan, tests and code**

```bash
git add Package.swift Sources/Sigil/Geometry.swift Sources/Sigil/OverlayController.swift Sources/Sigil/OverlayView.swift Tests/SigilTests/HintRoutingTests.swift docs/superpowers
git commit -m "fix(overlay): one hint panel per display so macOS never relocates the overlay"
```
