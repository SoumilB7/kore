import Foundation
import HostClient
import Testing

@testable import KoreUI

/// A box rekeyed to its KoreNet id is "mybox" on the Welcome (2026-11-15: its big title showed the
/// id while the switcher chip said "mybox"), in a copied chat's line and in the move's progress:
/// its own name, never the alias it was set up by (2026-11-24).
@MainActor
@Suite("welcome names a rekeyed box")
struct WelcomeTitleTests {
    @Test func aRekeyedBoxIsMyboxOnTheWelcomeAndInChatLines() {
        let device = UUID()
        let id = device.uuidString.lowercased()
        NodeDirectory.shared.upsert(.init(device: device, name: "mybox", ssh: "mybox-cf", nodeKey: "nodekey:b", identityKey: Data([1]), enrolled: true, rekeyed: true))
        defer { NodeDirectory.shared.forget(id) }
        #expect(WelcomeView.title(id) == "mybox")
        #expect(WelcomeView.title(nil) == "Kore")
        #expect(WelcomeView.title("plainbox") == "plainbox")
        let spot = ChatSpot.box(alias: id, folder: "/home/me/kore")
        #expect(spot.shown == "kore on mybox" && spot.destination == "mybox")
    }
}
