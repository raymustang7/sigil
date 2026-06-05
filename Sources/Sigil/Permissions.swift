import ApplicationServices

enum Permissions {
    /// Whether Sigil is currently trusted for Accessibility control.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Checks trust and, if `prompt` is true, asks the system to surface the
    /// "grant Accessibility access" prompt (which deep-links to System Settings).
    @discardableResult
    static func ensureTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
