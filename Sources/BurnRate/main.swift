import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Background menu-bar app: no Dock icon, always-present status item.
app.setActivationPolicy(.accessory)
app.run()
