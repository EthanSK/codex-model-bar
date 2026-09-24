import AppKit

// Entry point. The app is an accessory (LSUIElement): no Dock icon, no menu bar.
// AppController owns everything: window tracking, the bar panel, model loading and
// the switcher.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
app.delegate = controller
app.run()
