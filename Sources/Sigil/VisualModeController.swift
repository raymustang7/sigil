import AppKit
import ApplicationServices

/// Drives "Visual mode": hotkey → scan actionable elements → the user types the *visible text*
/// of a target (e.g. "issu" for a GitHub "Issues" tab). There is no query box; keystrokes are
/// captured silently. Once the candidate set narrows to ≤2 elements they're badged on screen,
/// and a unique best match also gets a confirmation popup that navigates on Return.
///
/// Matching is ranked exact → prefix → substring, so an exact label beats a longer one that
/// merely contains the query. Up to two ties are badged 1–2 and picked by pressing that digit;
/// digits are therefore reserved for selection, and the query is built from letters, spaces and
/// periods. Keys Visual mode uses (query keys, digit selection, confirm Return, the toggle, and
/// Esc/Delete while a query exists) are *consumed* so they don't also fire app/OS shortcuts;
/// anything it ignores — including modifier chords like Cmd+Tab — passes through untouched.
/// Mirrors the other mode controllers: all work is on the main thread except the AX traversal,
/// which runs off the run loop that services the event tap.
final class VisualModeController {
    private enum State {
        case idle
        /// Scan dispatched; swallow keys until elements are ready.
        case activating
        case active
    }

    private let overlay = OverlayController()
    private let panel = VisualOverlayController()
    private let scanner = AccessibilityScanner()
    private let scanQueue = DispatchQueue(label: "com.sigil.visual", qos: .userInteractive)

    /// User-managed list of apps/sites where Visual mode stays transparent.
    private let blocklist: Blocklist
    /// Cached "the current app/site is blocked" flag. Read on the per-keystroke path; refreshed
    /// asynchronously (URL reads use AppleScript, which can block) and applied on main.
    private var suppressedHere = false
    /// Slow safety poll that re-checks the blocked state while engaged on a browser — catches
    /// in-tab navigations that don't fire a focus/window change.
    private var suppressionPoll: Timer?
    private let suppressionQueue = DispatchQueue(label: "com.sigil.visual.suppress", qos: .userInitiated)

    private var state: State = .idle
    private var geometry = Geometry.snapshot()
    private var activeFrontPID: pid_t = 0

    /// Only elements that expose a usable label participate in matching.
    private var labelled: [ScannedElement] = []
    private var query = ""
    private var matches: [ScannedElement] = []

    /// Keystrokes typed while the activation scan is still running; replayed once it lands so the
    /// first letters of a query aren't lost to scan latency.
    private var pendingStrokes: [KeyStroke] = []

    /// The unique best match awaiting Return-to-navigate, if any.
    private var pendingTarget: ScannedElement?
    private var countdownTimer: Timer?
    private var countdownRemaining = 0

    /// Bumped each time `recompute` runs; lets an in-flight async visibility check discard its
    /// result if the query has moved on since it was dispatched.
    private var recomputeToken = 0

    /// Coalesces bursts of fast typing so the expensive rank-and-verify pass runs once the user
    /// pauses, rather than on every keystroke.
    private var debounceTimer: Timer?
    private let recomputeDebounce: TimeInterval = 0.12

    /// Cached "is a text field focused" state. Read on the per-keystroke path (which runs on the
    /// event-tap's main thread) and refreshed asynchronously, so we never make a synchronous —
    /// potentially slow — AX call while handling a keystroke.
    private var textInputFocused = false
    /// When the focus last transitioned into a text field. We only suppress matching once focus has
    /// been in a field for `textFieldStabilityWindow`, so brief/transient focus (e.g. the instant
    /// after a navigation) doesn't eat the first letters. The timestamp is driven by the focus
    /// *observer* below, so it reflects when focus actually entered the field — not when typing
    /// began — and so "already in a field" is recognised immediately.
    private var textInputFocusedSince: Date?
    private let textFieldStabilityWindow: TimeInterval = 0.3
    private let focusQueue = DispatchQueue(label: "com.sigil.visual.focus", qos: .userInteractive)

    /// Watches the front app for focus changes so `textInputFocused` updates the instant focus
    /// enters/leaves a text field, rather than lazily on the next keystroke (which, in the
    /// consume-keys model, would eat the keystrokes typed before detection caught up).
    private var axObserver: AXObserver?
    private var observedPID: pid_t = 0

    /// Hints (badges) appear only once the candidate set is this small; above it, the user keeps
    /// typing blind to narrow down. Doubles as the cap on numbered selection (1–2).
    private let hintThreshold = 2
    /// Only verify on-screen visibility once the candidate set is at most this big (each check is
    /// an AX hit-test); larger sets aren't rendered anyway, so there's nothing to verify yet.
    private let visibilityCheckCap = 4
    /// Seconds the confirmation popup waits for Return before dismissing.
    private let confirmSeconds = 3

    /// Fired on the main thread whenever the mode turns on (`true`) or off (`false`), so the UI
    /// can show a menu-bar indicator while Visual mode is engaged.
    var onActiveChange: ((Bool) -> Void)?

    /// Fired on the main thread whenever the typed query changes (including being cleared), so the
    /// menu bar can show what's currently being matched.
    var onQueryChange: ((String) -> Void)?

    /// Fired on the main thread whenever the current match count changes, so the dropdown can show
    /// how many elements match and prompt the user to keep typing when there are too many.
    var onMatchesChange: ((Int) -> Void)?

    /// Fired on the main thread when the mode becomes suppressed (`true`, with a label of the
    /// blocking app/site) or resumes (`false`, `nil`), so the UI can reflect "paused here".
    var onSuppressionChange: ((Bool, String?) -> Void)?

    private var workspaceObserver: NSObjectProtocol?

    var isActive: Bool { state != .idle }

    init(blocklist: Blocklist) {
        self.blocklist = blocklist

        // The mode is sticky and lets every key (incl. Cmd+Tab) through, so the front app can
        // change underneath us. When it does, the cached element set is stale — drop the query
        // and rescan the new front app so we never match a now-hidden window.
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, self.state == .active else { return }
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self.clearTyping()
            self.rescan()
        }
    }

    deinit {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        stopFocusObserver()
    }

    /// Ctrl + Cmd + Opt + Space. Distinct from hint mode (Ctrl+Space) and the switcher
    /// (Ctrl+Shift+Space), both of which exclude Cmd/Opt.
    func isActivationHotkey(_ stroke: KeyStroke) -> Bool {
        stroke.keyCode == KeyStroke.space
            && stroke.hasControl
            && stroke.hasCommand
            && stroke.hasOption
            && !stroke.hasShift
    }

    // MARK: - Key handling

    func handle(_ stroke: KeyStroke) -> Bool {
        switch state {
        case .idle:
            return false
        case .activating:
            // The scan isn't ready yet. Buffer query-building keys (and consume them, matching the
            // active-mode behaviour so they don't leak to the app) for replay once elements land;
            // pass everything else through.
            if isActivationHotkey(stroke) {
                exit()
                return true
            }
            // Don't buffer/consume while suppressed on a blocked app/site — stay transparent.
            if suppressedHere { return false }
            if isQueryBuildingKey(stroke) {
                pendingStrokes.append(stroke)
                return true
            }
            return false
        case .active:
            return handleActiveKey(stroke)
        }
    }

    /// Keys that Sigil actually uses are *consumed* so they don't also trigger the app's/OS's
    /// shortcuts: the toggle chord, the confirm Return (when there's a match), a digit that picks a
    /// badged tie, and the query keys (letters/space/period, plus Esc/Delete while a query exists).
    /// Everything else — modifier chords like Cmd+Tab, and any key Sigil ignores — passes through.
    private func handleActiveKey(_ stroke: KeyStroke) -> Bool {
        // The activation chord toggles the mode off.
        if isActivationHotkey(stroke) {
            exit()
            return true
        }

        // On a blocked app/site Visual mode goes transparent: every key (bar the toggle above)
        // passes straight through — no query building, no consumption.
        if suppressedHere { return false }

        // Return confirms a pending navigation — the one ordinary key we intercept.
        if stroke.keyCode == KeyStroke.returnKey || stroke.keyCode == KeyStroke.enterKey {
            if let target = pendingTarget {
                navigate(target)
                return true
            }
            if matches.count == 1 {
                navigate(matches[0])
                return true
            }
            // Nothing to navigate — let Return reach the app.
            return false
        }

        // A bare digit selects the matching numbered tie (consumed so it doesn't reach the app).
        // Only active while ties are badged, so digits are otherwise free to pass through.
        if let index = selectionIndex(stroke) {
            navigate(matches[index])
            return true
        }

        // Query keys are consumed; anything we don't use is passed through (returns false).
        return observe(stroke)
    }

    /// Whether a keystroke is one that builds the query (a letter, space, or period with no modifier
    /// chord) — used during activation to decide what to buffer and consume.
    private func isQueryBuildingKey(_ stroke: KeyStroke) -> Bool {
        if stroke.hasCommand || stroke.hasControl || stroke.hasOption { return false }
        guard let character = stroke.characters.first, stroke.characters.count == 1 else { return false }
        return character.isLetter || character == " " || character == "."
    }

    /// The 0-based match index a bare digit picks, or nil if it isn't a selection. Only valid when
    /// ties are currently badged (so digits pass through whenever there's nothing numbered).
    private func selectionIndex(_ stroke: KeyStroke) -> Int? {
        guard !stroke.hasCommand, !stroke.hasControl, !stroke.hasOption, !stroke.hasShift else { return nil }
        guard matches.count >= 2, matches.count <= hintThreshold else { return nil }
        guard stroke.characters.count == 1,
              let digit = stroke.characters.first?.wholeNumberValue,
              digit >= 1, digit <= matches.count else { return nil }
        return digit - 1
    }

    /// Update the query from a keystroke. Returns `true` if the key was *used* by Visual mode (and
    /// should therefore be consumed so it can't also fire an app/OS shortcut), `false` if Sigil
    /// ignored it and it should pass through to the app.
    private func observe(_ stroke: KeyStroke) -> Bool {
        // Shortcut chords aren't label typing — never consume them (so Cmd+Tab etc. still work).
        if stroke.hasCommand || stroke.hasControl || stroke.hasOption { return false }

        // Keep the focus state fresh for subsequent keystrokes without blocking this one.
        refreshFocusState()

        // While a text field is *stably* focused the keys belong to that field, not to matching —
        // pass them through. We read cached state (refreshed off-thread), never a synchronous call.
        if isStablyInTextField() {
            if !query.isEmpty { clearTyping() }
            return false
        }

        // Delete/Esc reset the query so a new target can be typed. Consume them only when there's a
        // query to clear (otherwise they're free to reach the app, e.g. Esc to close a dialog).
        // Refresh the snapshot too, so the next target matches the current screen.
        if stroke.keyCode == KeyStroke.escape || stroke.keyCode == KeyStroke.delete {
            if !query.isEmpty {
                clearTyping()
                rescan()
                return true
            }
            return false
        }

        // Letters, spaces and periods drive matching; spaces and periods let multi-word and
        // file-style labels (e.g. "pull requests", "Brand Logo.png", "Package.swift") be typed.
        // Digits are reserved for picking a numbered tie (handled in handleActiveKey), so they're
        // not query characters. Every other key is ignored here and flows to the app.
        guard let character = stroke.characters.first, stroke.characters.count == 1 else { return false }
        if character == " " || character == "." {
            // A space/period extends a name but never starts one (no leading space or period).
            if query.isEmpty { return false }
            query += String(character)
        } else if character.isLetter {
            query += character.lowercased()
        } else {
            return false
        }

        // Extending the query is cheap and the menu-bar indicator should track it live; the costly
        // rank-and-verify pass is debounced so a burst of typing triggers it just once.
        onQueryChange?(query)
        scheduleRecompute()
        return true
    }

    /// Debounce the expensive recompute: each keystroke reschedules it, so it fires only after a
    /// brief typing pause (web-app style), avoiding a background visibility pass per character.
    private func scheduleRecompute() {
        debounceTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: recomputeDebounce, repeats: false) { [weak self] _ in
            self?.recompute()
        }
        RunLoop.main.add(timer, forMode: .common)
        debounceTimer = timer
    }

    private func cancelScheduledRecompute() {
        debounceTimer?.invalidate()
        debounceTimer = nil
    }

    // MARK: - Lifecycle

    func activate() {
        Log.write("hotkey: Ctrl+Cmd+Opt+Space received — entering visual mode")
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            state = .idle
            return
        }
        state = .activating
        onActiveChange?(true)
        query = ""
        activeFrontPID = frontApp.processIdentifier
        geometry = Geometry.snapshot()
        ensureFocusObserver(pid: activeFrontPID)
        refreshFocusState()
        refreshSuppression()
        startSuppressionPoll()

        let pid = activeFrontPID
        let bounds = geometry.axBounds
        scanQueue.async { [weak self] in
            guard let self else { return }
            let elements = self.scanner.scanFocusedContext(frontmostPID: pid, axBounds: bounds)
            DispatchQueue.main.async {
                guard self.state == .activating else { return }
                self.labelled = elements.filter { !$0.label.isEmpty }
                Log.write("visual scan: \(elements.count) elements, \(self.labelled.count) labelled")
                self.state = .active
                // Replay anything typed during the scan so early letters aren't lost.
                let buffered = self.pendingStrokes
                self.pendingStrokes = []
                for stroke in buffered { _ = self.observe(stroke) }
                self.cancelScheduledRecompute()
                self.recompute()
            }
        }
    }

    /// Re-rank against the current query, badge any ≤2 candidates, and offer the popup when one
    /// element uniquely matches.
    ///
    /// Ranking is cheap (in-memory) and runs inline, but verifying that a candidate is genuinely
    /// visible costs synchronous AX hit-tests that can be slow for busy apps (e.g. Chrome). This
    /// method is reached from the event-tap callback on the *main* run loop, so those hit-tests are
    /// offloaded to `scanQueue` and the result applied back on main — otherwise a few quick
    /// keystrokes would stall the main thread (dropping the status item, tripping the tap timeout).
    private func recompute() {
        cancelCountdown()
        onQueryChange?(query)
        let ranked = Self.rank(query, in: labelled)

        // Sets too big to render don't need verifying (we won't badge them); apply inline.
        guard !query.isEmpty, ranked.count >= 1, ranked.count <= visibilityCheckCap else {
            applyMatches(ranked)
            return
        }

        recomputeToken += 1
        let token = recomputeToken
        scanQueue.async { [weak self] in
            guard let self else { return }
            // Drop any candidate that isn't actually on top at its reported location (covered,
            // hidden toolbar/overflow, stale frame) — prevents "phantom" hints over empty space.
            let visible = ranked.filter { self.isOnTopAtCenter($0) }
            DispatchQueue.main.async {
                guard self.state == .active, token == self.recomputeToken else { return }
                self.applyMatches(visible)
            }
        }
    }

    /// Commit a freshly computed candidate set on the main thread: badge it and offer the popup
    /// when exactly one element matches.
    private func applyMatches(_ newMatches: [ScannedElement]) {
        matches = newMatches
        onMatchesChange?(matches.count)
        renderBadges()

        if !query.isEmpty, matches.count == 1 {
            pendingTarget = matches[0]
            startConfirm(matches[0])
        } else {
            pendingTarget = nil
            panel.hide()
        }
    }

    /// Highlight matches once the candidate set is small. A lone match shows "↵" (press Return to
    /// go); ties are numbered 1–2 (top-to-bottom) and picked by pressing that digit, or narrowed
    /// by typing more.
    private func renderBadges() {
        guard matches.count >= 1, matches.count <= hintThreshold else {
            overlay.hide()
            return
        }
        let boxes: [HintBox] = matches.enumerated().map { index, element in
            let label = matches.count == 1 ? "↵" : "\(index + 1)"
            return HintBox(cocoaRect: geometry.cocoaGlobalRect(fromAX: element.frame), label: label)
        }
        overlay.show(boxes: boxes, geometry: geometry, typedPrefix: "")
    }

    private func startConfirm(_ target: ScannedElement) {
        countdownRemaining = confirmSeconds
        showConfirmPopup(target)
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.countdownRemaining -= 1
            if self.countdownRemaining <= 0 {
                // Timed out without a Return: dismiss the popup but stay engaged (no navigation).
                self.clearTyping()
            } else {
                self.showConfirmPopup(target)
            }
        }
        RunLoop.main.add(countdownTimer!, forMode: .common)
    }

    private func showConfirmPopup(_ target: ScannedElement) {
        panel.show(label: target.label, secondsRemaining: countdownRemaining)
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    private func navigate(_ target: ScannedElement) {
        // Visual mode is sticky: activate the target but remain engaged so the user can keep
        // navigating. Tear the overlays down first so a synthetic click lands on the app.
        clearTyping()
        DispatchQueue.main.async {
            ActionExecutor.execute(target)
        }
        // The activated UI usually changes (navigation, new view); refresh the element set after
        // it settles so subsequent typing matches what's now on screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.rescan()
        }
    }

    /// Reset the typing session (query, matches, overlays, countdown) without leaving the mode.
    private func clearTyping() {
        cancelScheduledRecompute()
        cancelCountdown()
        overlay.hide()
        panel.hide()
        query = ""
        matches = []
        pendingTarget = nil
        onQueryChange?("")
        onMatchesChange?(0)
    }

    /// Re-walk the current front app's focused window so continued navigation matches what's
    /// actually on screen now (after an in-app navigation, app switch, etc.).
    private func rescan() {
        guard state == .active, let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        activeFrontPID = frontApp.processIdentifier
        geometry = Geometry.snapshot()
        ensureFocusObserver(pid: activeFrontPID)
        refreshFocusState()
        refreshSuppression()
        let pid = activeFrontPID
        let bounds = geometry.axBounds
        scanQueue.async { [weak self] in
            guard let self else { return }
            let elements = self.scanner.scanFocusedContext(frontmostPID: pid, axBounds: bounds)
            DispatchQueue.main.async {
                guard self.state == .active else { return }
                self.labelled = elements.filter { !$0.label.isEmpty }
            }
        }
    }

    /// Fully leave Visual mode. Triggered only by the activation chord (toggle) or the menu item.
    func exit() {
        reset()
    }

    private func reset() {
        cancelScheduledRecompute()
        cancelCountdown()
        stopFocusObserver()
        stopSuppressionPoll()
        overlay.hide()
        panel.hide()
        labelled = []
        matches = []
        pendingStrokes = []
        pendingTarget = nil
        textInputFocused = false
        textInputFocusedSince = nil
        suppressedHere = false
        query = ""
        let wasActive = state != .idle
        state = .idle
        if wasActive { onActiveChange?(false) }
    }

    // MARK: - Blocklist suppression

    /// Re-evaluate whether the current app/site is blocked, updating the cached `suppressedHere`
    /// flag. App matching is cheap and synchronous; site matching needs the browser URL (AppleScript)
    /// and is offloaded. Called from the main thread (activation, focus events, the poll, list edits).
    func refreshSuppression() {
        // Feature unused ⇒ never suppress, and never touch AppleScript, so users who haven't
        // blocked anything are never shown an Automation prompt.
        if blocklist.apps.isEmpty, blocklist.domains.isEmpty {
            applySuppression(false, label: nil)
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication else {
            applySuppression(false, label: nil)
            return
        }
        let bundleID = front.bundleIdentifier ?? ""

        if blocklist.blocksApp(bundleID: bundleID) {
            applySuppression(true, label: front.localizedName ?? bundleID)
            return
        }

        // Only read a URL when there are blocked sites *and* the front app is a scriptable browser.
        guard !blocklist.domains.isEmpty, BrowserURLReader.isSupportedBrowser(bundleID: bundleID) else {
            applySuppression(false, label: nil)
            return
        }

        suppressionQueue.async { [weak self] in
            guard let self else { return }
            let host = BrowserURLReader.currentURL(bundleID: bundleID)?.host
            let blocked = host.map { self.blocklist.blocks(host: $0) } ?? false
            DispatchQueue.main.async {
                guard self.state == .active else { return }
                self.applySuppression(blocked, label: blocked ? host : nil)
            }
        }
    }

    /// Commit a freshly computed suppression state on the main thread. On entering suppression we
    /// tear down any in-progress typing/overlays so the mode is immediately transparent.
    private func applySuppression(_ value: Bool, label: String?) {
        guard value != suppressedHere else { return }
        suppressedHere = value
        if value { clearTyping() }
        onSuppressionChange?(value, label)
    }

    private func startSuppressionPoll() {
        stopSuppressionPoll()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshSuppression()
        }
        RunLoop.main.add(timer, forMode: .common)
        suppressionPoll = timer
    }

    private func stopSuppressionPoll() {
        suppressionPoll?.invalidate()
        suppressionPoll = nil
    }

    // MARK: - Focus detection

    /// Roles that accept text entry; while one is focused we pass keystrokes through to the app.
    private static let textInputRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField",
    ]

    /// (Re)install the focus observer for `pid`, if not already watching it. Fires `refreshFocusState`
    /// whenever the front app's focused element changes, so we learn focus entered/left a text field
    /// the moment it happens — not on the next keystroke.
    private func ensureFocusObserver(pid: pid_t) {
        guard pid != observedPID || axObserver == nil else { return }
        stopFocusObserver()

        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let controller = Unmanaged<VisualModeController>.fromOpaque(refcon).takeUnretainedValue()
            // A focus/window change can also mean a tab switch or navigation, so re-check both the
            // text-field state and whether we've landed on a blocked app/site.
            controller.refreshFocusState()
            controller.refreshSuppression()
        }

        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, app, kAXFocusedUIElementChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)

        axObserver = observer
        observedPID = pid
    }

    private func stopFocusObserver() {
        if let observer = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        axObserver = nil
        observedPID = 0
    }

    /// Recompute the cached text-input-focused flag off the main thread, so the per-keystroke path
    /// never blocks on a (possibly slow) AX query. Results are applied back on main.
    private func refreshFocusState() {
        focusQueue.async { [weak self] in
            guard let self else { return }
            let focused = self.isTextInputFocused()
            DispatchQueue.main.async {
                if focused != self.textInputFocused {
                    self.textInputFocused = focused
                    self.textInputFocusedSince = focused ? Date() : nil
                }
            }
        }
    }

    /// True only when a text field has held focus for at least `textFieldStabilityWindow` — so a
    /// momentary focus change doesn't suppress matching or drop the first letters of a query.
    private func isStablyInTextField() -> Bool {
        guard textInputFocused, let since = textInputFocusedSince else { return false }
        return Date().timeIntervalSince(since) >= textFieldStabilityWindow
    }

    /// Whether the system-wide focused element is a text input. Always called off the main thread
    /// (see `refreshFocusState`); a short messaging timeout guards against a slow app.
    private func isTextInputFocused() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        guard let value = AX.copyValue(system, kAXFocusedUIElementAttribute as String),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)
        return Self.isEditableTextElement(element)
    }

    /// Whether `element` accepts text entry. A role whitelist alone is unreliable: Electron/Chromium
    /// apps (Cursor, VS Code, Slack) surface their inputs with roles outside the native set, so a
    /// search box there would otherwise be missed and Visual mode would eat the keystrokes instead
    /// of letting them reach the box. We therefore also treat any element that exposes a text
    /// *selection range* with a *settable value* as editable text — a signal that holds for native
    /// fields and web/Electron inputs alike, while excluding read-only web areas (they expose a
    /// range but no settable value, so typing still drives matching on ordinary web pages) and
    /// controls like checkboxes or sliders (settable value but no text range).
    private static func isEditableTextElement(_ element: AXUIElement) -> Bool {
        if textInputRoles.contains(AX.role(element)) { return true }
        if let subrole = AX.string(element, kAXSubroleAttribute as String), subrole == "AXSearchField" {
            return true
        }
        let hasTextRange = AX.copyValue(element, kAXSelectedTextRangeAttribute as String) != nil
        return hasTextRange && AX.isSettable(element, kAXValueAttribute as String)
    }

    /// Whether `scanned` is the element actually on top at its own centre — i.e. genuinely
    /// visible. Hit-tests the screen point and walks up from whatever is topmost there; if it
    /// reaches our element, the element is visible. Catches covered windows and tree-resident but
    /// non-visible controls (hidden toolbars/overflow) whose frames would otherwise place a hint
    /// over empty space.
    private func isOnTopAtCenter(_ scanned: ScannedElement) -> Bool {
        let point = CGPoint(x: scanned.frame.midX, y: scanned.frame.midY)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)

        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let topmost = hit else {
            return false
        }

        // If our own overlay is on top here, we can't confirm what's underneath — treat as hidden.
        var pid: pid_t = 0
        if AXUIElementGetPid(topmost, &pid) == .success,
           pid == ProcessInfo.processInfo.processIdentifier {
            return false
        }

        var current: AXUIElement? = topmost
        var depth = 0
        while let element = current, depth < 30 {
            if CFEqual(element, scanned.element) { return true }
            current = Self.parent(of: element)
            depth += 1
        }
        return false
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        guard let value = AX.copyValue(element, kAXParentAttribute as String),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    // MARK: - Matching

    /// Rank elements by how well their label matches `query`: exact equality wins, then a prefix
    /// match, then a substring match. Only the best non-empty tier is returned (so an exact match
    /// is never diluted by longer labels that merely contain the query), sorted top-to-bottom for
    /// stable badge numbering.
    static func rank(_ query: String, in elements: [ScannedElement]) -> [ScannedElement] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }

        var exact: [ScannedElement] = []
        var prefix: [ScannedElement] = []
        var substring: [ScannedElement] = []
        for element in elements {
            let label = element.label.lowercased()
            if label == q {
                exact.append(element)
            } else if label.hasPrefix(q) {
                prefix.append(element)
            } else if label.contains(q) {
                substring.append(element)
            }
        }

        let tier = !exact.isEmpty ? exact : (!prefix.isEmpty ? prefix : substring)
        return tier.sorted { lhs, rhs in
            lhs.frame.minY != rhs.frame.minY ? lhs.frame.minY < rhs.frame.minY
                                             : lhs.frame.minX < rhs.frame.minX
        }
    }
}
