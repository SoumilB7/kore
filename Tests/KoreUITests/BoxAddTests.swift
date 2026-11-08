import Foundation
import HostClient
import Testing

@testable import KoreUI

/// Adding a box (Devices' "Add a box", the Welcome "+"): what it offers by KoreNet's state and the
/// release, the release asked once a run, and the alias field gone once an alias is picked.
@MainActor
@Suite("adding a box")
struct BoxAddTests {
    static let peer = ClaimPeer(name: "box-2", address: "100.64.0.9", nodeKey: "nodekey:box-2", login: "me@example.com")

    @Test func koreNetOffOffersSSHAndNewBoxOnly() {
        let choices = BoxAddChoices.make(net: .off, found: [Self.peer], release: true)
        #expect(choices.found.isEmpty && choices.ssh && choices.newBox && !choices.sshOnly)
        // Tailscale off or not signed in: the tailnet's boxes can't be reached either.
        for net in [DevicesPicture.Net.stopped, .signedOut, .notJoined, .starting] {
            #expect(BoxAddChoices.make(net: net, found: [Self.peer], release: true).found.isEmpty)
        }
    }

    @Test func koreNetOnOffersTheBoxesFoundToo() {
        let choices = BoxAddChoices.make(net: .running, found: [Self.peer], release: true)
        #expect(choices == BoxAddChoices(found: [Self.peer], newBox: true) && choices.ssh)
    }

    @Test func noneFoundLeavesSSHAndNewBox() {
        let choices = BoxAddChoices.make(net: .running, found: [], release: true)
        #expect(choices.found.isEmpty && choices.newBox && choices.ssh)
    }

    @Test func newBoxOnlyWhileTheReleaseHasItsScript() {
        #expect(!BoxAddChoices.make(net: .running, found: [Self.peer], release: false).newBox)
        #expect(BoxAddChoices.make(net: .off, found: [], release: nil).sshOnly)
        #expect(BoxAddChoices.make(net: .off, found: [], release: false).sshOnly)
    }

    @Test func theReleaseIsAskedOnceARun() async {
        final class Count: @unchecked Sendable { var n = 0 }
        let asks = Count()
        let with = HostRelease { asks.n += 1; return (200, Data(#"{"tag_name":"v0.3.0","assets":[{"name":"kore-host.sh"},{"name":"SHA256SUMS"}]}"#.utf8)) }
        await with.check()
        await with.check()
        #expect(with.hasScript == true && asks.n == 1)

        // v0.2.3: a release with no assets at all.
        let without = HostRelease { (200, Data(#"{"tag_name":"v0.2.3","assets":[]}"#.utf8)) }
        await without.check()
        #expect(without.hasScript == false)
        #expect(HostRelease.hasScript(status: 404, data: Data()) == false)
        #expect(HostRelease.hasScript(status: 403, data: Data()) == nil)
        #expect(HostRelease.hasScript(status: 200, data: Data("not json".utf8)) == nil)

        // Offline: nothing kept, the next opening asks again.
        asks.n = 0
        let offline = HostRelease { asks.n += 1; return nil }
        await offline.check()
        await offline.check()
        #expect(offline.hasScript == nil && asks.n == 2)
    }

    @Test func thePickedAliasClosesTheFieldForGood() {
        var state = WelcomeSwitch()
        state.adding = ""
        state.typed("myb")
        #expect(state.adding == "myb")
        state.show("mybox")
        // The field hands its text back as it goes: it stays closed over the set-up.
        state.typed("mybox")
        #expect(state.adding == nil && state.place == "mybox")
    }
}
