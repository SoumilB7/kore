import Foundation
import KoreUI

/// Kore Phone: Kore with the phone remote. `kore-phone` installs it before the app starts; Kore
/// itself never does, and carries none of this module.
@MainActor
package enum KorePhone {
    package private(set) static var installed = false

    /// Called once, before the app starts. The Mac's own controls (the "/" entry and the
    /// title-row button) are added here once they exist; the host waits until the owner turns
    /// the remote on.
    package static func install() {
        guard !installed else { return }
        installed = true
        _ = RemoteHost.shared
        PhoneUI.install()
    }

    /// Takes the Mac's controls out again (a storyline that installed them, finished).
    package static func uninstall() {
        guard installed else { return }
        installed = false
        RemoteHost.shared.service.disable()
        PhoneUI.uninstall()
    }
}
