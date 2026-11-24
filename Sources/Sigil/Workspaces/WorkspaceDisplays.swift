import Cocoa

struct WorkspaceDisplay {
    var key: String
    var name: String
    /// Global top-left-origin frame.
    var frame: ScreenRect
}

enum WorkspaceDisplays {
    static func all() -> [WorkspaceDisplay] {
        guard let main = NSScreen.screens.first else { return [] }
        let mainHeight = main.frame.maxY
        return NSScreen.screens.map { s in
            let f = s.frame
            let rect = ScreenRect(x: Int(f.minX), y: Int(mainHeight - f.maxY), w: Int(f.width), h: Int(f.height))
            return WorkspaceDisplay(key: key(for: s), name: s.localizedName, frame: rect)
        }
    }

    /// Stable-ish identity for a physical display: vendor/model/serial, falling back to its name.
    static func key(for screen: NSScreen) -> String {
        if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let id = CGDirectDisplayID(num.uint32Value)
            let vendor = CGDisplayVendorNumber(id)
            let model = CGDisplayModelNumber(id)
            let serial = CGDisplaySerialNumber(id)
            if vendor != 0 || model != 0 {
                return "\(vendor)-\(model)-\(serial)"
            }
        }
        return "name:" + screen.localizedName
    }

    static func display(containing rect: ScreenRect, in displays: [WorkspaceDisplay]) -> WorkspaceDisplay? {
        displays.first { $0.frame.contains(rect.centerX, rect.centerY) } ?? displays.first
    }
}
