import AppKit

/// Reads the active tab's URL from a supported browser via AppleScript. Used to decide whether the
/// frontmost browser is on a blocked site.
///
/// AppleScript is synchronous and can block if the target app is busy, so every call must be made
/// **off the main thread**. All failures (no permission, scripting error, unsupported browser) are
/// swallowed and surface as `nil` — the caller treats "unknown" as "not blocked" (fail-open), so a
/// missing Automation grant never silently disables Visual mode.
enum BrowserURLReader {
    /// Whether `bundleID` is a browser we know how to script. Lets callers skip the (costly) URL
    /// read and the safety poll for non-browsers.
    static func isSupportedBrowser(bundleID: String) -> Bool {
        script(for: bundleID) != nil
    }

    /// The active tab's URL for the given browser, or nil if it can't be read.
    static func currentURL(bundleID: String) -> URL? {
        guard let source = script(for: bundleID) else { return nil }
        guard let apple = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = apple.executeAndReturnError(&error)
        guard error == nil, let string = result.stringValue, !string.isEmpty else { return nil }
        return URL(string: string)
    }

    /// AppleScript that fetches the front window's active-tab URL, or nil for unsupported bundles.
    /// The Chromium family (Chrome, Edge, Brave, Arc, …) shares Chrome's scripting dictionary;
    /// Safari uses "current tab". Firefox is not scriptable for URL and returns nil.
    private static func script(for bundleID: String) -> String? {
        if safariBundleIDs.contains(bundleID) {
            return "tell application id \"\(bundleID)\" to get URL of current tab of front window"
        }
        if chromiumBundleIDs.contains(bundleID) {
            return "tell application id \"\(bundleID)\" to get URL of active tab of front window"
        }
        return nil
    }

    private static let safariBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
    ]

    private static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "company.thebrowser.Browser", // Arc
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]
}
