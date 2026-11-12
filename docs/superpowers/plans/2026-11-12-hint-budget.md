# Fair Hint Budget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the front-to-back 250-result cap with a user-configurable budget (default 800) shared equally across visible windows, with two-keystroke labels up to 1225.

**Architecture:** The scanner collects candidates per window first, then a pure allocator decides how many each window keeps. `HintGenerator` picks a 26- or 35-character alphabet by count. A `SigilSettings` store persists the budget; a new AppKit Settings window edits it.

**Tech Stack:** Swift 6 toolchain (Swift 5 mode), AppKit, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-12-hint-budget-design.md`

## Global Constraints

- Budget range `100...1225`, default `800`, key `com.sigil.hintBudget`.
- Alphabet: letters `ASDFGHJKLQWERTYUIOPZXCVBNM`; digits `123456789` appended only when count > 676.
- Allocation: equal share, surplus redistributed to still-short windows, remainder units to earlier windows. Menu bar and Dock off the top.
- Collection bounds: total nodes 12000, per-window nodes 6000, deadline 1.5 s.
- Scanner remains main-thread-free; settings read on main and passed in.

## Review Focus

1. Budget smaller than menu bar + Dock demand → windows get 0, no crash, no negative numbers. → Task 1 `testZeroBudgetGivesZeros`, Task 3 reservation capped at budget.
2. More windows than budget units (e.g. 150 tiny windows, budget 100) → share rounds to 0; the last units must still be handed out one per window, never loop forever. → Task 1 `testMoreWindowsThanBudgetHandsOutSingles`.
3. Deadline trips mid-window → partial candidates for that window are kept, later sources empty, log reports it. → Task 3 manual + log check.
4. Typing a digit while hints use the 26-letter alphabet must be ignored (beep), not crash or match. → Task 1 `testAlphabetRule` + Task 3 accepted-set built from `alphabet(forCount:)`.
5. Settings field with non-numeric or out-of-range text → clamped on commit, never written raw. → Task 2 `testClampsOutOfRange`, Task 4 formatter + clamp on commit.

---

### Task 1: Allocator and alphabet rule

**Files:** Create `Sources/Sigil/HintBudget.swift`; Modify `Sources/Sigil/HintGenerator.swift`; Create `Tests/SigilTests/HintBudgetTests.swift`, `Tests/SigilTests/HintGeneratorTests.swift`.

**Interfaces (produces):**
```swift
enum HintBudget {
    static func allocate(demands: [Int], budget: Int) -> [Int]
}
extension HintGenerator {
    static let digitAlphabet = Array("123456789")
    static let twoCharacterLetterLimit = 676          // 26 * 26
    static func alphabet(forCount count: Int) -> [Character]
}
// generate(count:) now uses alphabet(forCount:) when the instance was created with the default alphabet.
```

- [ ] Write failing tests: `testRun1At250` → `[38, 90, 32, 90]`; `testCursorHypothetical` `[900,150,150]`@800 → `[500,150,150]`; `testWithinBudgetUnchanged`; `testZeroBudgetGivesZeros`; `testMoreWindowsThanBudgetHandsOutSingles` (150×[5], budget 100 → sum 100, each ≤1, first 100 windows get 1); `testEmptyDemands` → `[]`. Generator: `testAlphabetRule` (676 → 26 chars, 677 → 35 chars, first 26 are the letters); `test676LabelsAreLetterOnlyTwoChars`; `test1225LabelsUniquePrefixFreeTwoChars`; `testSmallCountsUnchanged` (count 10 → 10 single letters).
- [ ] Run: `swift test --filter 'HintBudgetTests|HintGeneratorTests' 2>&1 | tail -5` → compile errors.
- [ ] Implement `HintBudget.allocate` (water-filling loop; when `remaining / short.count == 0` hand out one unit each to the first `remaining` short windows and stop) and the alphabet rule.
- [ ] Run again → `0 failures`.

### Task 2: Settings store

**Files:** Create `Sources/Sigil/SigilSettings.swift`; Create `Tests/SigilTests/SigilSettingsTests.swift`.

**Interfaces (produces):**
```swift
final class SigilSettings {
    static let shared = SigilSettings()
    static let defaultHintBudget = 800
    static let hintBudgetRange = 100...1225
    static let hintBudgetKey = "com.sigil.hintBudget"
    init(defaults: UserDefaults = .standard)
    var hintBudget: Int { get set }       // clamped; persisted; fires onChange
    var onChange: (() -> Void)?
    func resetHintBudget()
}
```
- [ ] Tests with `UserDefaults(suiteName: "SigilSettingsTests-<uuid>")`: `testDefaultIs800`; `testPersistsAcrossInstances`; `testClampsOutOfRange` (50 → 100, 5000 → 1225); `testResetRestoresDefault`; `testOnChangeFires`.
- [ ] Run → compile errors. Implement. Run → `0 failures`.

### Task 3: Scanner collects, then allocates

**Files:** Modify `Sources/Sigil/AccessibilityScanner.swift` (remove the uncommitted diag block; new signature), `Sources/Sigil/HintModeController.swift`, `Sources/Sigil/VisualModeController.swift` (pass budget).

**Interfaces:** consumes Task 1 + Task 2.
```swift
func scanVisibleWindows(frontmostPID: pid_t, axBounds: CGRect, budget: Int) -> [ScannedElement]
func scanFocusedContext(frontmostPID: pid_t, axBounds: CGRect, budget: Int) -> [ScannedElement]
```
`traverse` gains a `CollectionLimits` (deadline `DispatchTime`, per-window visited cap) and stops when any bound trips; `maxResults` is removed. `HintModeController.activate()` reads `SigilSettings.shared.hintBudget`; `finishScan` sets `hintAlphabet = Set(HintGenerator.alphabet(forCount: labels.count))`.

- [ ] Implement per the spec's steps 1–5; log line `scan: windows=W/W' candidates=C hints=H trimmed=T budget=B in Xms`.
- [ ] `swift build` clean; `swift test` → `0 failures`.

### Task 4: Settings window and menu item

**Files:** Create `Sources/Sigil/SettingsWindow.swift`; Modify `Sources/Sigil/AppDelegate.swift`.

- [ ] `SettingsWindowController.show()` builds (once) an `NSWindow` titled "Sigil Settings" with the "Hint budget" row (number field with `NumberFormatter` min/max = range, `NSStepper` increment 50), caption, "Reset to Default"; commits clamp through `SigilSettings.shared`; `NSApp.activate(ignoringOtherApps: true)` then `makeKeyAndOrderFront`.
- [ ] Menu: "Settings…" (⌘,) before "Open Accessibility Settings…", target `self`, action opens the window.
- [ ] `swift build` clean.

### Task 5: Verify and commit

- [ ] `ARCHS=arm64 ./scripts/bundle.sh release && pkill -x Sigil; open .build/Sigil.app`; user runs the two-Chrome-windows scenario on 3 displays, then sets budget 100 and 800 via Settings.
- [ ] Expected log: `scan: windows=4/4 ... trimmed=0 budget=800`; with 100: `hints=100`, every window non-zero.
- [ ] On the user's go-ahead commit code, tests, docs.
