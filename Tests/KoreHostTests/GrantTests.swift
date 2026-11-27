import Foundation
import Synchronization
import Testing

@testable import KoreHost
@testable import LinkProtocol

@Suite("Box grants")
struct GrantTests {
    @Test func allowWritesAPrivateGrantAndRevokeRemovesIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kh-grants-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = GrantStore(folder)
        let grant = try store.allow("laptop", control: .full, socket: URL(fileURLWithPath: "/tmp/x.sock"))
        #expect(Data(base64Encoded: grant.secret)?.count == 32)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("laptop.json").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let dir = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((dir[.posixPermissions] as? Int) == 0o700)
        #expect(store.load("laptop") == grant)
        #expect(store.all().map(\.name) == ["laptop"])
        #expect(store.revoke("laptop"))
        #expect(store.load("laptop") == nil)
        #expect(throws: GrantError.self) { try store.allow("../x", control: .act, socket: URL(fileURLWithPath: "/tmp/x.sock")) }
    }
}

@Suite("gh on the box")
struct GitHubLoginTests {
    /// Tests never reach this Mac's own `gh`: a test box asks the fake on a connect, and every
    /// box or kore-host a test makes goes through `forTest` or the fake's `PATH`.
    @MainActor @Test func testBoxesNeverRunTheRealGh() async throws {
        let rig = try HostRig()
        defer { rig.finish() }
        try rig.host.start()
        let grant = try GrantStore(rig.paths.grants).allow("laptop", control: .full, socket: rig.paths.socket)
        let before = FakeGh.calls.count
        let client = try Client(rig.paths.socket)
        try await until { !client.got.isEmpty }
        client.hello(grant: grant)
        try await until { FakeGh.calls.count > before }
        #expect(FakeGh.calls.last == "auth status --hostname github.com")
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(files.count > 100)
        for file in files where file.lastPathComponent != "TestBoxes.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let made = "HostDaemon" + "(paths:"
            #expect(!text.contains(made), "\(file.lastPathComponent) makes a box without forTest")
            let spawned = text.contains("[" + "\"run\"]") && text.contains("ProcessInfo.processInfo.environment")
            #expect(!spawned || text.contains("FakeGh.path"), "\(file.lastPathComponent) runs kore-host with the real PATH")
        }
    }

    /// Many boxes' `gh` at once, none answering: they hold no thread, so the work a box does off
    /// the main thread still runs (its own tailnet's start and stop waited on them once).
    @Test func aSlowGhHoldsNoThread() async throws {
        let gate = "/tmp/kgh-\(UUID().uuidString.prefix(8))"
        #expect(mkfifo(gate, 0o600) == 0)
        let fd = open(gate, O_RDWR)
        defer { close(fd); unlink(gate) }
        let asked = (0..<40).map { _ in Task.detached(priority: .utility) { await GitHubLogin.run(["/bin/sh", "-c", "read x < \(gate)"]) } }
        try await Task.sleep(for: .milliseconds(300))
        let ran = Mutex(false)
        DispatchQueue.global(qos: .utility).async { ran.withLock { $0 = true } }
        let end = ContinuousClock.now + .seconds(10)
        while !ran.withLock({ $0 }), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(ran.withLock { $0 }, "the utility queue waits on gh")
        let lines = [UInt8](repeating: 10, count: 40)
        #expect(write(fd, lines, 40) == 40)
        for task in asked { #expect(await task.value == 0) }
    }

    @Test func theCodeAndPageAreReadFromGhsOutput() {
        let said = """
            ! Failed to copy one-time code to clipboard
            ! First copy your one-time code: 8811-2366
            Open this URL to continue in your web browser: https://github.com/login/device
            """
        let found = GitHubLogin.parse(said)
        #expect(found?.code == "8811-2366")
        #expect(found?.url == "https://github.com/login/device")
        #expect(GitHubLogin.parse("! First copy your one-time code: 8811-2366") == nil)
    }
}
