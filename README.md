# Sigil

A keyboard-first navigation layer for macOS.

Press a global hotkey, and Sigil overlays short keyboard hints ("sigils") on every visible,
actionable UI element across all on-screen windows. Type a hint to click, focus, or activate
that element without touching the mouse. A second hotkey opens a window switcher so you can
jump to any window or app by typing its name.

Universal UI hinting via the macOS Accessibility APIs

## Screenshots

**Hint mode** : short labels on every actionable element:

![Sigil hint mode, light hints](docs/images/sigil-light-mode.png)

![Sigil hint mode, dark hints](docs/images/sigil-dark-mode.png)

**Window switcher** : type a window title or app name and pick a numbered result:

![Sigil window switcher](docs/images/sigil-window-search.png)

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

The app runs as a menu-bar agent.

## Default keys

**Hint mode**

- **Control + Space** — toggle hint mode
- Type a hint to activate its element
- **Esc** — cancel
- **Delete** — undo the last typed character

**Window switcher**

- **Control + Shift + Space** — open the window switcher
- Type a window title or app name to filter
- **1–9** or **Return** — focus the chosen result
- **Esc** — cancel

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
