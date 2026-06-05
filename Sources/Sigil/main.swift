import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Background agent: no Dock icon, no app menu — Sigil lives in the menu bar.
application.setActivationPolicy(.accessory)
application.run()
