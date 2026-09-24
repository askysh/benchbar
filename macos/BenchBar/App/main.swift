import AppKit

// BenchBar uses the AppKit app lifecycle: a plain NSApplication with our
// AppDelegate. SwiftUI is used only for the views inside the popover and
// the Settings window (hosted with NSHostingController).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
