# Sigil

A keyboard-first navigation layer for macOS.

Press a global hotkey, and Sigil overlays short keyboard hints on every visible,
actionable UI element across all on-screen windows. Type a hint to click, focus, or activate
that element without touching the mouse. A second hotkey opens a window switcher so you can
jump to any window or app by typing its name. A third — *Visual mode* — lets you type an
element's visible text (e.g. `issu` for a GitHub **Issues** tab) and activate it once it's the
only match.

Universal UI hinting via the macOS Accessibility APIs

## How it works

| Step | Component |
|------|-----------|
| Intercept global hotkeys and route keystrokes to the active mode | `InputTap` (`CGEventTap`) / `InputCoordinator` |
| Walk every visible window's Accessibility tree for actionable elements | `AccessibilityScanner` |
| Generate short, unique, prefix-free labels | `HintGenerator` (Vimium-style) |
| Convert AX ↔ Cocoa coordinates across all displays | `Geometry` |
| Render labels in a click-through, always-on-top window | `OverlayController` / `OverlayView` |
| Activate the target (AXPress → focus → synthetic click) | `ActionExecutor` |
| Tie hint mode together (hotkey → scan → render → execute) | `HintModeController` |
| Search and focus windows by name | `WindowSwitcher` / `WindowSwitcherController` / `SwitcherOverlay` |
| Match elements by their visible text and confirm-to-activate | `VisualModeController` / `VisualOverlay` |

The app runs as a menu-bar agent.

## Default keys

**Hint mode**

- **Control + Space** — toggle hint mode
- Type a hint to activate its element
- **Esc** — cancel
- **Delete** — undo the last typed character

- Hints cover every visible window on every display. Up to a **hint budget** of elements are
  labelled (default 800, adjustable in **Settings…** from the menu-bar menu), shared fairly
  across windows so a busy front window never starves the ones behind it. Labels are two
  letters; digits join the alphabet only when a scan needs more than 676 hints.

**Window switcher**

- **Control + Shift + Space** — open the window switcher
- Type a window title or app name to filter
- **1–9** or **Return** — focus the chosen result
- **Esc** — cancel

**Visual mode** (sticky — stays on until you toggle it off)

> **Currently disabled** while it is evaluated: the hotkey is ignored and its menu items (including
> the app/site blocklist, which only affects Visual mode) are hidden. Re-enable via
> `SigilSettings.visualModeEnabled`.

- **Control + Command + Option + Space** — toggle Visual mode on/off
- While engaged, the menu-bar icon shows an eye badge on the `⌘`; the live query appears in the
  Sigil dropdown menu
- Matches only the **frontmost app's focused window** (and its menu bar), and re-scans on app
  switches — so typed text never matches a background app or a stale/covered layout
- Type an element's visible text (no input box); matches are ranked exact → prefix → substring
- The query is built from **letters, spaces and periods** (spaces/periods can't be the first
  character), so names like `pull requests` or `Package.swift` are typeable
- **Key capture:** keys Visual mode uses are *consumed* so they don't also fire app/OS shortcuts —
  the query keys, the **digit** that picks a numbered tie, the confirm **Return**, the toggle
  chord, and **Esc/Delete** while a query exists. Everything it ignores — modifier chords
  (Cmd+Tab, Cmd+`` ` ``), arrows, other punctuation — passes through untouched. While a text field
  is focused, keys pass through so you can type into it normally.
- Once **2 or fewer** elements match they're highlighted on screen (numbered 1–2 when tied); keep
  typing to narrow, or press the **digit** to pick a tie
- A unique best match gets an "↵ navigate to …" popup (centred, 1/3 down the screen) — press
  **Return** within 3s to go there
- After navigating the mode stays engaged and re-scans, so you can keep moving around
- **Delete** removes the last character; **Cmd+Delete** or **Esc** clears the whole query (none
  exit the mode)
- Exit via the hotkey again, or **Exit Visual Mode** in the menu-bar menu

**Blocklist** (Visual mode only) — keep the mode out of apps/sites where it gets in the way:

- From the menu bar: **Block This App** (the frontmost app), **Block This Site** (the current
  browser tab's domain), **Add Blocked Site…** (type a domain like `youtube.com`), and a
  **Blocked ▸** submenu to remove entries
- On a blocked app or site Visual mode goes transparent — every key passes straight through and no
  query is built — while staying engaged, so it resumes the moment you leave. The dropdown shows
  *"Paused on …"* while suppressed
- Site matching covers subdomains (`youtube.com` blocks `www.`/`m.`/`music.youtube.com`)
- The current site is read via the browser's scripting interface (Safari and Chrome-based browsers;
  Firefox can't expose its URL, so block it by app instead). This needs **Automation permission**
  for that browser — macOS prompts the first time. If it's denied or unavailable, Sigil simply
  doesn't suppress (it never silently stops working)

> Window titles are read via the Accessibility API, which only exposes windows on the current
> Space. Windows on other Spaces are reachable by their app name.

## Requirements

- macOS 13+
- Xcode / Swift 6 toolchain
- **Accessibility permission** (System Settings → Privacy & Security → Accessibility).
  Sigil prompts on first launch; the menu-bar item shows a ⚠︎ until access is granted, then
  starts automatically.

## Build & run

```bash
# Build and assemble a code-signed .app bundle
./scripts/bundle.sh

# Launch it
open .build/Sigil.app
```

> A real `.app` bundle is required: macOS keys Accessibility permission on bundle identity, so
> running the bare SwiftPM binary leads to flaky permission behaviour.

For a quick compile check during development:

```bash
swift build
```
