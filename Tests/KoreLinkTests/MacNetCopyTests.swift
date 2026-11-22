import Foundation
import HostClient
import KoreTrust
import Testing

@testable import KoreLink

/// Which boxes a phone's copy may touch, by this Mac's records. In `MacNetTests`' suite, as its
/// other rigs are.
extension MacNetTests {
    @Test func aPhonesCopyReachesOnlyABoxThatHoldsThePhonesRecordFromHere() throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let devices = MacNetDevices { rig.net }
        let pixel = Phone(), box = UUID()
        func line(_ phone: UUID? = pixel.id, _ at: UUID? = box) -> String? { rig.net.refusesCopy(phone, box: at, name: "mybox") }
        let no = "This phone isn't allowed on mybox"
        func entry(enrolled: Bool = true, pushed: NodeDirectory.Pushed?) {
            var entry = NodeDirectory.Entry(device: box, name: "mybox", ssh: "mybox", nodeKey: nil, identityKey: Data([1]), enrolled: enrolled)
            entry.pushed = pushed
            rig.host.directory.upsert(entry)
        }
        let took = NodeDirectory.Pushed(by: rig.host.device, bookRev: 1, boxRev: 1)
        entry(pushed: took)
        // Never allowed here.
        #expect(line() == no)
        try rig.allow(pixel)
        #expect(line() == nil)
        // A box this Mac doesn't know, isn't enrolled on, or that took nothing (or another Mac's) from here.
        #expect(line(pixel.id, UUID()) == no && line(pixel.id, nil) == no && line(nil) == no && line(UUID()) == no)
        entry(enrolled: false, pushed: took)
        #expect(line() == no)
        entry(pushed: nil)
        #expect(line() == no)
        entry(pushed: .init(by: UUID(), bookRev: 1, boxRev: 1))
        #expect(line() == no)
        entry(pushed: took)
        #expect(line() == nil)
        // Taken offline, and back.
        devices.setPaused(pixel.id, true)
        #expect(line() == no)
        devices.setPaused(pixel.id, false)
        #expect(line() == nil)
        // Only watching.
        try rig.host.book.update { for i in $0.indices where $0[i].id == pixel.id { $0[i].abilities = [.read] } }
        #expect(line() == no)
        try rig.host.book.update { for i in $0.indices where $0[i].id == pixel.id { $0[i].abilities = [.read, .ask] } }
        #expect(line() == nil)
        // Removed.
        devices.remove(pixel.id)
        #expect(line() == no)
    }
}
