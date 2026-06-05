import AppKit
import CoreGraphics

/// A decoded keyboard event handed to the controller.
struct KeyStroke {
    let keyCode: Int64
    let flags: CGEventFlags
    /// Layout-aware characters ignoring modifiers, uppercased (e.g. "A"). May be empty.
    let characters: String

    var hasControl: Bool { flags.contains(.maskControl) }
    var hasCommand: Bool { flags.contains(.maskCommand) }
    var hasOption: Bool { flags.contains(.maskAlternate) }
    var hasShift: Bool { flags.contains(.maskShift) }

    // Common virtual key codes.
    static let escape: Int64 = 53
    static let delete: Int64 = 51
    static let space: Int64 = 49
    static let returnKey: Int64 = 36
    static let enterKey: Int64 = 76
}

/// Low-level keyboard interceptor built on a session-level `CGEventTap`.
///
/// All `keyDown` events flow through `onKeyDown`. Returning `true` consumes the event so the
/// focused application never sees it (essential while typing hints); returning `false` lets it
/// pass through untouched.
final class InputTap {
    /// Return `true` to consume the event, `false` to pass it through.
    var onKeyDown: ((KeyStroke) -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: Timer?

    /// Creates and enables the tap. Requires Accessibility permission; returns `false` if the
    /// system refuses to create the tap (typically because permission has not been granted).
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue()
                return tap.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source

        // Safety net: if macOS ever disables the tap (e.g. after a slow callback or system
        // sleep) and the inline re-enable is missed, this brings it back. Cheap to poll.
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                Log.write("watchdog: event tap was disabled — re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        return true
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that is too slow or after wake; re-enable and pass through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.write("event tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "userInput")) — re-enabling")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown, let handler = onKeyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let characters = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.uppercased() ?? ""
        let stroke = KeyStroke(keyCode: keyCode, flags: event.flags, characters: characters)

        let consume = handler(stroke)
        return consume ? nil : Unmanaged.passUnretained(event)
    }
}
