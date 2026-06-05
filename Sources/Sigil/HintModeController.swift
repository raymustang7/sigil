import AppKit

/// Drives the full hint-mode lifecycle: hotkey detection → scan → render → key capture →
/// execute. All work runs on the main thread (the event tap is attached to the main run loop),
/// so AppKit and Accessibility calls are safe to make directly.
final class HintModeController {
    enum State {
        case idle
        /// Scan dispatched; swallow keys but ignore them until hints appear.
        case activating
        case active
    }

    private let overlay = OverlayController()
    private let scanner = AccessibilityScanner()
    private let hintGenerator = HintGenerator()

    private var state: State = .idle
    private var geometry = Geometry.snapshot()
    private var hintToElement: [String: ScannedElement] = [:]
    private var boxes: [HintBox] = []
    private var typedBuffer = ""
    private var activeFrontPID: pid_t = 0
    private let scanQueue = DispatchQueue(label: "com.sigil.scan", qos: .userInteractive)

    private let hintAlphabet = Set(HintGenerator.defaultAlphabet)

    /// Whether hint mode is currently showing or preparing hints.
    var isActive: Bool { state != .idle }

    /// Ctrl + Space (without other modifiers).
    func isActivationHotkey(_ stroke: KeyStroke) -> Bool {
        stroke.keyCode == KeyStroke.space
            && stroke.hasControl
            && !stroke.hasCommand
            && !stroke.hasOption
            && !stroke.hasShift
    }

    // MARK: - Key handling

    /// Handle a key while this mode is active. Returns `true` to consume the event.
    func handle(_ stroke: KeyStroke) -> Bool {
        switch state {
        case .idle:
            return false

        case .activating:
            // Hints not shown yet; swallow stray input so it doesn't leak to the app.
            if stroke.keyCode == KeyStroke.escape { cancel() }
            return true

        case .active:
            return handleActiveKey(stroke)
        }
    }

    private func handleActiveKey(_ stroke: KeyStroke) -> Bool {
        switch stroke.keyCode {
        case KeyStroke.escape:
            cancel()
            return true

        case KeyStroke.delete:
            if !typedBuffer.isEmpty {
                typedBuffer.removeLast()
                refreshOverlay()
            }
            return true

        default:
            guard let character = stroke.characters.first,
                  stroke.characters.count == 1,
                  hintAlphabet.contains(character) else {
                // Non-hint key while active: swallow it to keep capture exclusive.
                return true
            }
            appendHintCharacter(character)
            return true
        }
    }

    private func appendHintCharacter(_ character: Character) {
        let candidate = typedBuffer + String(character)

        let matches = hintToElement.keys.contains { $0.hasPrefix(candidate) }
        guard matches else {
            // Dead end — ignore the keystroke, keep current state.
            NSSound.beep()
            return
        }

        typedBuffer = candidate
        if let target = hintToElement[candidate] {
            execute(target)
        } else {
            refreshOverlay()
        }
    }

    // MARK: - Lifecycle

    func activate() {
        Log.write("hotkey: Ctrl+Space received — entering hint mode")
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            state = .idle
            return
        }
        state = .activating
        activeFrontPID = frontApp.processIdentifier
        // Capture display geometry on the main thread, then scan off-thread.
        geometry = Geometry.snapshot()
        scan(isRetry: false)
    }

    /// Runs the (potentially expensive) AX traversal on a background queue so the main run loop
    /// — which services the event tap — is never blocked. Results are handed back to the main
    /// thread to build the overlay.
    private func scan(isRetry: Bool) {
        let pid = activeFrontPID
        let bounds = geometry.axBounds
        scanQueue.async { [weak self] in
            guard let self else { return }
            let start = DispatchTime.now()
            let elements = self.scanner.scanVisibleWindows(frontmostPID: pid, axBounds: bounds)
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            DispatchQueue.main.async {
                self.finishScan(elements: elements, isRetry: isRetry, elapsedMs: elapsedMs)
            }
        }
    }

    private func finishScan(elements: [ScannedElement], isRetry: Bool, elapsedMs: Double) {
        // The user may have cancelled (Esc) while the scan was in flight.
        guard state == .activating else { return }

        let frontName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        Log.write(String(format: "scan (retry=%@): frontmost=%@ elements=%d in %.0fms",
                         isRetry ? "true" : "false", frontName, elements.count, elapsedMs))

        guard !elements.isEmpty else {
            // A freshly-enabled Chromium/Electron accessibility tree may still be building.
            // Give it a beat and try once more before giving up.
            if !isRetry {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self, self.state == .activating else { return }
                    self.scan(isRetry: true)
                }
            } else {
                state = .idle
            }
            return
        }

        let labels = hintGenerator.generate(count: elements.count)
        hintToElement.removeAll(keepingCapacity: true)
        boxes.removeAll(keepingCapacity: true)
        typedBuffer = ""

        for (label, element) in zip(labels, elements) {
            hintToElement[label] = element
            boxes.append(HintBox(
                cocoaRect: geometry.cocoaGlobalRect(fromAX: element.frame),
                label: label
            ))
        }

        overlay.show(boxes: boxes, geometry: geometry, typedPrefix: "")
        state = .active
    }

    private func refreshOverlay() {
        overlay.updatePrefix(typedBuffer, boxes: boxes, geometry: geometry)
    }

    private func execute(_ target: ScannedElement) {
        reset()
        // Let the overlay tear down before activating, so a synthetic click lands on the app.
        DispatchQueue.main.async {
            ActionExecutor.execute(target)
        }
    }

    private func cancel() {
        reset()
    }

    private func reset() {
        overlay.hide()
        hintToElement.removeAll(keepingCapacity: true)
        boxes.removeAll(keepingCapacity: true)
        typedBuffer = ""
        state = .idle
    }
}
