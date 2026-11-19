import AppKit

// BenchBar uses the AppKit app lifecycle: a plain NSApplication with our
// AppDelegate. SwiftUI is used only for the views inside the popover and
// the BenchBar window (hosted with NSHostingController).
//
// A second copy (another path: Homebrew's, a DMG, ~/Applications, Xcode)
// opens the running one and quits at once, before it makes a store or a link.
if SingleInstance.yieldToRunningCopy() { exit(0) }
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
