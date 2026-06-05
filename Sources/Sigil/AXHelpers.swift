import ApplicationServices
import CoreGraphics

/// Thin, ergonomic wrappers around the C Accessibility (AXUIElement) APIs.
/// These never throw; on any failure they return `nil`/empty so traversal can
/// keep moving instead of unwinding.
enum AX {
    static func copyValue(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return result == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copyValue(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copyValue(element, attribute) as? Bool
    }

    static func role(_ element: AXUIElement) -> String {
        string(element, kAXRoleAttribute as String) ?? ""
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let value = copyValue(element, kAXChildrenAttribute as String) else { return [] }
        // AXUIElement is a CFType; CFArray bridges to [AXUIElement].
        return value as? [AXUIElement] ?? []
    }

    static func windows(_ application: AXUIElement) -> [AXUIElement] {
        guard let value = copyValue(application, kAXWindowsAttribute as String) else { return [] }
        return value as? [AXUIElement] ?? []
    }

    /// Element bounds in global screen coordinates (top-left origin, y growing down) — the
    /// native Accessibility coordinate space.
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard
            let positionValue = copyValue(element, kAXPositionAttribute as String),
            let sizeValue = copyValue(element, kAXSizeAttribute as String)
        else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point) else { return nil }
        guard AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// Fetch several attributes in a single IPC round-trip. Far cheaper than one call per
    /// attribute when traversing large trees. Returns an array parallel to `attributes`; entries
    /// for missing/failed attributes are `nil`.
    static func multiAttributes(_ element: AXUIElement, _ attributes: [String]) -> [AnyObject?] {
        var raw: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &raw
        )
        guard result == .success, let values = raw as? [AnyObject], values.count == attributes.count else {
            return Array(repeating: nil, count: attributes.count)
        }
        // Failed attributes come back as an AXValue wrapping an AXError; callers detect those by
        // failing their expected type-casts, so we pass values through as-is.
        return values.map { $0 }
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        let result = AXUIElementCopyActionNames(element, &names)
        guard result == .success, let array = names as? [String] else { return [] }
        return array
    }

    @discardableResult
    static func perform(_ element: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }

    @discardableResult
    static func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(
            element,
            attribute as CFString,
            value ? kCFBooleanTrue : kCFBooleanFalse
        ) == .success
    }
}
