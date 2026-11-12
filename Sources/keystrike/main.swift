import AppKit

// Menu-bar entry point: an agent app (no Dock icon, no main window).
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
