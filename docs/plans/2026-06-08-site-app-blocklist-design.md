# Visual-mode site & app blocklist — design

**Date:** 2026-06-08
**Status:** Accepted, pre-implementation

## Problem

Visual mode is *sticky*: once engaged it silently observes every alphanumeric
keystroke (to build a match query) until toggled off. On some sites and apps the
user never wants that interference — e.g. typing on `youtube.com`, or inside a
particular app. We need a user-managed blocklist that makes Visual mode go
transparent on those sites/apps, while staying engaged so it resumes elsewhere.

Scope is **Visual mode only**. Hint mode and the window switcher are explicitly
invoked, modal, and exit immediately, so they are intentionally unaffected — a
blocklist that disabled their hotkeys would just feel broken.

## Decisions

- **URL source:** AppleScript / Apple Events (accurate full URL). The Chromium
  family (Chrome, Edge, Brave, Arc) shares Chrome's scripting dictionary; Safari
  has its own variant. Firefox is not scriptable for URL and is unsupported.
- **App blocking:** match the frontmost app's **bundle identifier**. No URL, no
  AppleScript, no extra permission — cheap and synchronous.
- **Adding entries:** *Block this app* (current frontmost), *Block this site*
  (current tab), and *Add blocked site…* (typed domain). No typed app entry
  (name→bundle-ID matching is fiddly; YAGNI). A *Blocked ▸* submenu lists Apps
  and Sites, each removable.
- **Fail-open:** any uncertainty (no Automation permission, wedged browser,
  unknown app, scripting error) ⇒ *not suppressed*, so Sigil never silently dies.

## Architecture

### `Blocklist.swift` (new, model)

Persisted in `UserDefaults`:

- `blockedApps: [(bundleID: String, name: String)]` — name cached for the menu.
- `blockedDomains: [String]` — normalized: lowercased, scheme/path/query stripped,
  leading `www.` dropped, trimmed. `https://www.YouTube.com/feed` ⇒ `youtube.com`.
- `addApp`, `removeApp(bundleID:)`, `addDomain(raw:)`, `removeDomain(_:)`.
- `blocksApp(bundleID:) -> Bool` — exact match.
- `blocks(host:) -> Bool` — `host == domain` **or** `host.hasSuffix("." + domain)`,
  so `youtube.com` covers `www.`/`m.`/`music.youtube.com`.
- `onChange: (() -> Void)?` — fired on mutation so the menu rebuilds.

### `BrowserURLReader.swift` (new)

`func currentURL(bundleID:) -> URL?`

- Known browser bundle IDs → AppleScript source:
  - Chromium family: `get URL of active tab of front window`
  - Safari: `get URL of current tab of front window`
  - else (incl. Firefox) → `nil`.
- Runs **off the main thread** (callers dispatch it), so a hung browser can never
  stall the event tap. Any `NSAppleScript` error / permission denial → `nil`.

### `VisualModeController` integration

- New cached `suppressedHere: Bool`, plus `currentHostDescription: String?` (for
  the tooltip), mirroring the existing `textInputFocused` / `refreshFocusState`
  pattern.
- `refreshSuppression()` (async, result applied on main):
  1. frontmost app's bundle ID in `blockedApps` ⇒ suppress.
  2. else app is a known browser ⇒ read URL → host → `blocks(host:)`.
  3. else ⇒ not suppressed.
- **Triggers** (never the per-keystroke path):
  - `NSWorkspace.didActivateApplicationNotification` (already observed),
  - the existing focus `AXObserver`,
  - **new** `kAXTitleChangedNotification` on the focused window — window titles
    change on real navigations and tab switches, exactly when the host can change,
  - a ~2s safety poll, only while `state == .active` and the front app is a browser.
- On flip **→ true**: immediately `clearTyping()` + hide overlays (transparent
  without waiting for a keystroke).
- **Key path** (`handleActiveKey`): the toggle chord is handled first (always able
  to exit); then `if suppressedHere { return false }` ⇒ full passthrough, no query
  building, no consumption.

### `AppDelegate` menu

A single shared `Blocklist` instance, injected into both the controller (via
`InputCoordinator`) and the menu. New items:

- *Block this app* — captures frontmost app's bundle ID + localized name.
- *Block this site* — reads current tab host via `BrowserURLReader` (async; only
  meaningful in a browser).
- *Add blocked site…* — `NSAlert` with a text field; normalized on add.
- *Blocked ▸* submenu — **Apps** and **Sites** sections, each entry removable;
  rebuilt on `Blocklist.onChange`.

### Build

Add `NSAppleEventsUsageDescription` to `bundle/Info.plist` so the macOS Automation
prompt is allowed when Sigil first scripts a browser.

## Edge cases

- **SPA navigation** within `youtube.com` keeps the host the same ⇒ stays
  suppressed correctly.
- **Omnibox typing:** AppleScript returns the committed tab URL, not the in-progress
  omnibox text, so suppression doesn't flicker while typing a new address.
- **Permission not yet granted:** reader returns `nil` ⇒ not suppressed; the first
  *Block this site* / refresh triggers the prompt.
- **Non-scriptable browser (Firefox):** never suppressed by site (documented limit);
  the whole app can still be blocked via *Block this app*.
