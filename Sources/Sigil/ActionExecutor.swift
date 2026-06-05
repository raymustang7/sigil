import AppKit
import ApplicationServices

/// Activates a resolved element. Prefers semantic Accessibility actions and falls back to a
/// synthetic mouse click at the element's centre when no usable action is exposed.
enum ActionExecutor {
    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField",
    ]

    static func execute(_ scanned: ScannedElement) {
        let element = scanned.element

        // Semantic AX actions (AXPress, focus) operate on the element directly regardless of
        // z-order and activate it in place. A synthetic click is a real click — macOS won't
        // deliver it to a non-focused window without activating that window first — so it is
        // used only when no AX action applies, and raises the target window when needed.

        // Text inputs: focusing is the useful action, not "pressing".
        if textRoles.contains(scanned.role) {
            if AX.setBool(element, kAXFocusedAttribute as String, true) {
                return
            }
            click(scanned)
            return
        }

        if scanned.prefersSyntheticClick {
            Log.write("execute: web content role=\(scanned.role) via synthetic click")
            click(scanned)
            return
        }

        let actions = AX.actions(element)
        if actions.contains(kAXPressAction as String), AX.perform(element, kAXPressAction as String) {
            Log.write("execute: role=\(scanned.role) via AXPress")
            return
        }
        // Some controls expose more specific actions.
        for action in [kAXConfirmAction as String, kAXPickAction as String, kAXIncrementAction as String] where actions.contains(action) {
            if AX.perform(element, action) {
                Log.write("execute: role=\(scanned.role) via \(action)")
                return
            }
        }

        Log.write("execute: role=\(scanned.role) via fallback synthetic click")
        click(scanned)
    }

    /// Posts a synthetic click at the element centre. If the element's window isn't the focused
    /// window, it is raised first and the click deferred a beat, since a coordinate click only
    /// registers in the focused window.
    private static func click(_ scanned: ScannedElement) {
        let point = CGPoint(x: scanned.frame.midX, y: scanned.frame.midY)

        guard let window = windowElement(of: scanned.element), !isFocusedWindow(window) else {
            syntheticClick(atAX: point)
            return
        }

        var pid: pid_t = 0
        if AXUIElementGetPid(scanned.element, &pid) == .success,
           let app = NSRunningApplication(processIdentifier: pid) {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
        AX.perform(window, kAXRaiseAction as String)
        Log.write("execute: raised target window before click")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            syntheticClick(atAX: point)
        }
    }

    /// The AX window an element belongs to, if it exposes one.
    private static func windowElement(of element: AXUIElement) -> AXUIElement? {
        guard let value = AX.copyValue(element, kAXWindowAttribute as String),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Whether `window` is the currently focused window of the frontmost app.
    private static func isFocusedWindow(_ window: AXUIElement) -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        guard let focused = AX.copyValue(appElement, kAXFocusedWindowAttribute as String),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        return CFEqual(window, focused)
    }

    /// Posts a left mouse down/up at the given point. `point` is in Accessibility/Quartz global
    /// coordinates (top-left origin), which is exactly what `CGEvent` mouse posting expects.
    private static func syntheticClick(atAX point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
