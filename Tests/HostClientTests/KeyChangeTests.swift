import Foundation
import HostClient
import KoreCore
import KoreTrust
import Synchronization
import Tailnet
import Testing

/// After 0.3.7's new keys: the box rows that say what to do, and Kore's own tailnet over state
/// sealed under another key.
@Suite("key change", .serialized) @MainActor
struct KeyChangeTests {
    /// KoreNet off, a 0.3.6 box over SSH that doesn't know this Mac: update it, not just "doesn't know".
    @Test func anOldBoxThatDoesntKnowThisMacSaysUpdateKoreHost() {
        var box = BoxList.Box(alias: "mybox")
        box.status = .noGrant
        var machine = BoxMachine()
        machine.koreHost = "kore-host 0.3.6"
        box.machine = machine
        #expect(box.note == BoxList.Note(line: "mybox doesn't know this Mac · update kore-host on mybox", action: .setUp))
        machine.koreHost = "kore-host 0.3.7"
        box.machine = machine
        #expect(box.note == BoxList.Note(line: "mybox doesn't know this Mac", action: .setUp))
        box.machine = nil
        #expect(box.note?.line == "mybox doesn't know this Mac")
        #expect(BoxList.Box.beforeRekey("0.2.9") && !BoxList.Box.beforeRekey("0.10.0") && !BoxList.Box.beforeRekey("dev"))
    }

    /// A box claimed over the tailnet with no SSH: the row names the commands to run there.
    @Test func aTailnetOnlyBoxWithTheOldKeySaysWhatToRunThere() {
        let mac = UUID(uuidString: "0009A0E9-1111-4222-8333-444455556666")!
        let line = KoreNetSwitch.oldKeyLine("mybox", mac: mac)
        #expect(line == "mybox has this Mac's old key · on mybox run kore-host devices remove '\(DeviceRecord.code(mac))', then kore-host join, and Allow it here")
        #expect(HostConnection.Refused.oldKey(line).line("mybox") == line)
        #expect(BoxList.status("mybox", phase: .refused(.oldKey(line)), reason: "bye unknown") == .unreachable(line, nil))
    }

    /// State sealed under another key (a race between two Kore processes, or the Keychain's old
    /// key): dropped and started once more; a sign-in it held is said to be needed again.
    @Test func stateSealedUnderAnotherKeyIsDroppedAndStartedOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("key-change-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let calls = EnvCalls()
        let fake = FakeTailnet(.needsLogin)
        let base = fakeEnv(.state(.stopped), sidecar: fake, root: root, defaults: defaults, calls: calls)
        let state = base.support.appendingPathComponent("net/tailnet/state/state.sealed")
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The key is there already (no fresh path): only the helper's own refusal drops the state.
        try base.secrets.write(Data(repeating: 1, count: 32), MacIdentity.tailnetAccount)
        try Data("sealed".utf8).write(to: state)
        let tries = Tally()
        var env = base
        let start = base.sidecar
        env.sidecar = { key in
            tries.add()
            if FileManager.default.fileExists(atPath: state.path) { throw TailnetError.sidecar(TailnetError.wrongStateKey) }
            return try start(key)
        }
        let (_, resealed) = try KoreNetSwitch.startSidecar(env)
        #expect(resealed && tries.count == 2 && !FileManager.default.fileExists(atPath: state.path))
        // Another failure isn't retried.
        env.sidecar = { _ in tries.add(); throw TailnetError.sidecar("didn't start") }
        #expect(throws: TailnetError.self) { _ = try KoreNetSwitch.startSidecar(env) }
        #expect(tries.count == 3)
        // A first key with no state before: nothing to sign in again.
        let fresh = fakeEnv(.state(.stopped), sidecar: fake, root: root.appendingPathComponent("b"), defaults: suite(), calls: calls)
        #expect(try KoreNetSwitch.startSidecar(fresh).resealed == false)
    }

    @Test func theSignInAgainLineShowsUntilKoresTailnetIsSignedIn() {
        #expect(KoreNetSwitch.signInAgainLine == "Kore's tailnet needs signing in again after the key change")
    }
}

/// A count closures can share.
final class Tally: Sendable {
    private let held = Mutex(0)
    func add() { held.withLock { $0 += 1 } }
    var count: Int { held.withLock { $0 } }
}
