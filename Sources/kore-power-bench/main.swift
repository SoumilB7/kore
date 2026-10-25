import AppKit
import KoreUI

final class PowerDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DevPowerBench.start()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = PowerDelegate()
app.delegate = delegate
app.run()
withExtendedLifetime(delegate) {}
