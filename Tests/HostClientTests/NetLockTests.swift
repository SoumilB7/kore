import Foundation
import Tailnet
import Testing

@testable import HostClient

/// Tailnet Lock's kept-out nodes as Devices lists them (G16): "needs a signature", Sign only when
/// this Mac holds a trusted lock key.
@Suite("net lock")
struct NetLockTests {
    static func lock(enabled: Bool = true, trusted: Bool) -> TailnetLock {
        let keys = trusted ? #"[{"Kind":"25519","Key":"tlpub:me","Votes":1}]"# : #"[{"Kind":"25519","Key":"tlpub:other","Votes":1}]"#
        let json = #"{"Enabled":\#(enabled),"PublicKey":"tlpub:me","TrustedKeys":\#(keys),"FilteredPeers":[{"Name":"kore-pixel-9.tail1234.ts.net.","ID":5,"NodeKey":"nodekey:p9","TailscaleIPs":["100.64.0.9"]},{"Name":"kore-pixel-9.tail1234.ts.net.","NodeKey":"nodekey:p9"}]}"#
        return try! JSONDecoder().decode(TailnetLock.self, from: Data(json.utf8))
    }

    @Test func aMacHoldingALockKeyOffersSign() {
        let rows = SignatureRow.rows(Self.lock(trusted: true))
        #expect(rows == [SignatureRow(nodeKey: "nodekey:p9", name: "kore-pixel-9", canSign: true)])
        #expect(rows[0].phone)
    }

    @Test func withoutALockKeyTheRowSaysWhereToSign() {
        let rows = SignatureRow.rows(Self.lock(trusted: false))
        #expect(rows.map(\.canSign) == [false])
        #expect(SignatureRow.help == "Sign it from a device that holds your lock key")
    }

    @Test func lockOffOrUnreadableListsNothing() {
        #expect(SignatureRow.rows(Self.lock(enabled: false, trusted: true)).isEmpty)
        #expect(SignatureRow.rows(nil).isEmpty)
    }
}
