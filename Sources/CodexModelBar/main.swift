import AppKit

// Exercise the final bundle's actual loader without starting AX, login items,
// keyboard routing, a toolbar or an update check on a build/test worker.
if CommandLine.arguments.contains("--check-packaged-launch") {
    let info = Bundle.main.infoDictionary ?? [:]
    let value = ["packagedLaunch": "ok", "version": info["CFBundleShortVersionString"] as? String ?? "dev",
                 "build": info["CFBundleVersion"] as? String ?? "dev"]
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}

// Entry point. The app is an accessory (LSUIElement): no Dock icon, no menu bar.
// AppController owns everything: window tracking, the bar panel, model loading and
// the switcher.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
app.delegate = controller
app.run()
