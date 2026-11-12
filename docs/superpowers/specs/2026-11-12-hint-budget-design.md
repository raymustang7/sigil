# Fair hint budget with a configurable cap — design

**Date:** 2026-11-12 · **Status:** approved

## Intent

Hints must cover every visible window, not just whichever windows the scanner reaches first.
The user must be able to tune how many hints Sigil shows from a Settings window.

## Root cause (confirmed with per-window logs)

`AccessibilityScanner` stops after 250 results. Windows are walked front to back and depth
first, so the budget is spent on the front window and whatever comes first inside it; later
windows (and the back half of a window, e.g. Chrome's tab strip after its page) get nothing.
Recorded runs: front Chrome window 204, second Chrome window 8 before the cap, two windows never
reached; on another run a whole display got 0 hints. Fully observed demand was 246–376
elements, so the cap sat right at the working set and z-order shuffles flipped hints on and off.

## Goals

- Every visible window gets hints whenever the budget allows; small windows are never trimmed
  while a larger one still has surplus (equal share, leftovers passed on — simulated against the
  recorded runs; see `scratch sim`: at 800 nothing recorded is lost).
- Total budget is a user setting (default 800, range 100–1225) applied on the next activation.
- Labels stay at two keystrokes for the whole range.

## Non-goals

- Smarter ranking of which elements inside a window matter most beyond "native before web".
- Changing Visual mode's matching; it only inherits the budget as its scan cap.
- Other settings in the new window (it is built to take more rows later).

## Anti-goals

- Any rule where a window with few elements loses hints while a big window keeps a surplus.
- Scan latency unbounded by anything but element count.

## Constraints

- Hint labels are prefix-free and globally unique; digits are added only when needed.
- Scanner stays safe to run off the main thread; settings are read on the main thread at
  activation and passed in.
- Pure, unit-tested allocation and alphabet selection.

## Approaches considered

| Allocation | Simulation result (runs replayed at cap 250 / hypothetical loads) | |
|---|---|---|
| Front to back (today) | background windows lose 75–100% | current |
| Proportional to element count | every window loses the same ~32%, small ones included | dropped |
| **Equal share, leftovers passed on** | small windows lose 0%, only the largest is trimmed | **chosen** |

| Settings surface | | |
|---|---|---|
| **Settings window** (new, AppKit, one row now) | home for future options | **chosen** |
| Alert dialog like "Add Blocked Site…" | cheapest, not a page | dropped |

## Design

**Settings store** — `SigilSettings` (new file), `UserDefaults` key `com.sigil.hintBudget`,
`hintBudget` clamped to `100...1225`, default `800`, `onChange` callback. Read by
`HintModeController.activate()` and `VisualModeController` on the main thread and passed to the
scanner as a parameter.

**Alphabet** — `HintGenerator.alphabet(forCount:)`: 26 letters when `count <= 676`, otherwise
letters followed by `1…9` (35 characters, 1225 two-character labels). `generate(count:)` uses it;
`HintModeController` builds its accepted-key set from the same call after each scan.

**Scanner** — `scanVisibleWindows(frontmostPID:axBounds:budget:)`:
1. Collect candidates per source: one list per visible window (front to back), one for the menu
   bar, one for the Dock. Collection is bounded by the existing total node ceiling (12000), a new
   per-window node ceiling (6000), and a wall-clock deadline (1.5 s from scan start); when a bound
   trips, remaining sources get nothing and the log says so.
2. Dedupe identical frames across all candidates, preserving order.
3. Order each window's candidates native-first (`prefersSyntheticClick == false`), then web, each
   group in traversal order.
4. Menu bar and Dock take their candidates off the top (capped at the budget). The remainder is
   allocated across windows by `HintBudget.allocate(demands:budget:) -> [Int]` (equal share,
   surplus redistributed to still-short windows until exhausted; remainders go to earlier
   windows). Each window keeps its first `n` candidates.
5. Log: `scan: windows=W/W' candidates=C hints=H trimmed=T budget=B in Xms`.

**Settings window** — `SettingsWindowController` (new file): titled "Sigil Settings"; row "Hint
budget" with a number field + stepper (step 50, range 100–1225), caption "Maximum hints shown at
once. Shared fairly across visible windows; higher values add a little scan time.", and
"Reset to Default". Opened from a new "Settings…" menu item (⌘,) placed before "Open Accessibility
Settings…". Activates the app when shown (accessory app).

## Left to the builder

- Exact layout constants of the settings window.
- Whether the Dock/menu-bar reservation is logged separately.

## Verification

- Unit: allocator on run 1 at 250 → `[38, 90, 32, 90]`; `[900,150,150]` at 800 → `[500,150,150]`;
  demands within budget are returned unchanged; zero budget → zeros; alphabet rule at 676/677/1225;
  1225 labels unique, prefix-free, all two characters; settings clamp and default.
- Manual on 3 displays: two Chrome windows on one display both get tab-strip hints; the Dell and
  laptop keep hints; log shows `trimmed=0`; set budget to 100 in Settings → next activation shows
  ~100 hints spread across windows; reset → 800.
