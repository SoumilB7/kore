import Foundation
import Testing

@testable import HostClient
@testable import KoreHost
@testable import LinkProtocol

/// A box's files as a test holds them: whether it says 1.12's `fsOps2`, and the verbs it was
/// asked. The 1.12 verbs answer from what the test set.
@MainActor
private final class OpsBox: BoxFileSource {
    let alias = "box"
    let fsOps2: Bool
    var asked: [String] = []
    var stat: BoxStat? = BoxStat(files: 3, bytes: 4096, free: 1 << 30)
    var found: Set<String> = ["a.txt", "src/b.txt"]
    init(fsOps2: Bool) { self.fsOps2 = fsOps2 }

    func syncApply(root: String, deletes: [String], mkdirs: [String]) async -> Result<BoxApplied, HostRefusal> {
        asked.append("sync.apply \(root) \(deletes.joined(separator: ","))")
        return .success(BoxApplied(deleted: deletes.count))
    }
    func stat(_ path: String) async -> Result<BoxStat?, HostRefusal> {
        asked.append("fs.stat \(path)")
        return .success(stat)
    }
    func find(_ path: String) async -> Result<Set<String>?, HostRefusal> {
        asked.append("fs.find \(path)")
        return .success(found)
    }
    func trashLanding(_ path: String) async -> Result<Void, HostRefusal> {
        asked.append("fs.delete landing \(path)")
        return .success(())
    }
    func trash(_ path: String) async -> Result<Void, HostRefusal> {
        asked.append("fs.delete \(path)")
        return .success(())
    }

    func list(_ path: String?, hidden: Bool) async -> Result<BoxListing, HostRefusal> { .failure(HostRefusal(message: "no")) }
    func read(_ path: String, max: Int?, base: FileStamp?) async -> Result<BoxFileRead, HostRefusal> { .failure(HostRefusal(message: "no")) }
    func makeFolder(_ path: String) async -> Result<String, HostRefusal> { .failure(HostRefusal(message: "no")) }
    func write(_ path: String, _ bytes: Data, base: FileStamp?) async -> Result<FileStamp, BoxWriteFailure> {
        .failure(.refused("no"))
    }
    func create(_ path: String, folder: Bool) async -> Result<String, HostRefusal> { .failure(HostRefusal(message: "no")) }
    func rename(_ from: String, to: String) async -> Result<String, HostRefusal> { .failure(HostRefusal(message: "no")) }
    func search(_ root: String, _ query: String, text: Bool, max: Int, pages: (@MainActor ([FileHit]) -> Void)?)
        async -> Result<(hits: [FileHit], more: Bool), HostRefusal>
    { .failure(HostRefusal(message: "no")) }
    func watch(_ key: String, _ folders: Set<String>, changed: (@MainActor (BoxChange) -> Void)?) async -> Bool { false }
}

/// Link 1.12 on the Mac: a box that says `fsOps2` is asked its verbs and no shell runs; an older
/// box gets the `sh -c` over SSH as before. The SSH stand-in runs the command here and writes
/// each call to a log.
@Suite("box file verbs or the shell", .serialized)
@MainActor
struct FsOpsFallbackTests {
    struct Rig {
        let root: URL
        let work: URL
        let ssh: SyncBox
        var log: URL { root.appendingPathComponent("ssh.log") }

        init() throws {
            root = URL(fileURLWithPath: "/tmp/kfo-\(UUID().uuidString.prefix(6))")
            work = root.appendingPathComponent("work")
            try FileManager.default.createDirectory(at: work.appendingPathComponent("src"), withIntermediateDirectories: true)
            for path in ["a.txt", "src/b.txt"] { try Data("x".utf8).write(to: work.appendingPathComponent(path)) }
            let program = root.appendingPathComponent("ssh")
            try Data("""
                #!/bin/sh
                while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
                shift; shift
                echo "$*" | head -1 >> "\(root.path)/ssh.log"
                exec /bin/sh -c "$*"
                """.utf8).write(to: program)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
            ssh = SyncBox.via(program.path, alias: "box", base: root.path)
        }

        var shellRuns: Int { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count }
        func there(_ path: String) -> Bool { FileManager.default.fileExists(atPath: work.appendingPathComponent(path).path) }
        func finish() { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: Sync deletes

    @Test func anOlderBoxDeletesByTheShell() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let box = OpsBox(fsOps2: false)
        #expect(await HostSync.deleteOnBox(["src/b.txt"], in: rig.work.path, files: box, box: rig.ssh, low: false) == nil)
        #expect(!rig.there("src/b.txt") && !rig.there("src") && rig.there("a.txt"))
        #expect(rig.shellRuns > 0 && box.asked.isEmpty)
    }

    @Test func aNewBoxIsAskedSyncApply() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let box = OpsBox(fsOps2: true)
        #expect(await HostSync.deleteOnBox(["src/b.txt"], in: rig.work.path, files: box, box: rig.ssh, low: false) == nil)
        #expect(box.asked == ["sync.apply \(rig.work.path) src/b.txt"])
        #expect(rig.shellRuns == 0 && rig.there("src/b.txt"))
    }

    @Test func aLongDeleteListGoesInTurnsUnderTheCap() {
        let paths = (0..<(LinkFsOps.applyMax * 2 + 5)).map { (true, "f\($0)") }
        let turns = HostConnection.turns(paths)
        #expect(turns.map(\.count) == [LinkFsOps.applyMax, LinkFsOps.applyMax, 5])
        let long = (0..<200).map { (true, String(repeating: "x", count: 1000) + "\($0)") }
        #expect(HostConnection.turns(long).allSatisfy { $0.reduce(0) { $0 + $1.1.utf8.count } <= LinkFsOps.applyBytes })
    }

    // MARK: Pairing's look at the box

    @Test func anOlderBoxIsCountedByTheShell() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let box = OpsBox(fsOps2: false)
        let stat = try #require(try await HostSync.boxSide(rig.work.path, via: rig.ssh, link: box).get())
        #expect(stat.files == 2 && stat.free > 0)
        #expect(rig.shellRuns == 1 && box.asked.isEmpty)
    }

    @Test func aNewBoxIsAskedFsStat() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let box = OpsBox(fsOps2: true)
        #expect(try await HostSync.boxSide(rig.work.path, via: rig.ssh, link: box).get() == box.stat)
        box.stat = nil
        #expect(try await HostSync.boxSide(rig.work.path, via: rig.ssh, link: box).get() == nil)
        #expect(rig.shellRuns == 0)
    }

    // MARK: Carries

    @Test func anOlderBoxIsListedByFind() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let box = OpsBox(fsOps2: false)
        let carry = CarryBox(alias: "box", files: box, ssh: rig.ssh)
        #expect(await carry.listing(rig.work.path) == ["a.txt", "src/b.txt"])
        #expect(rig.shellRuns == 1 && box.asked.isEmpty)
    }

    @Test func aNewBoxIsAskedFsFind() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let box = OpsBox(fsOps2: true)
        box.found = ["only.txt"]
        let carry = CarryBox(alias: "box", files: box, ssh: rig.ssh)
        #expect(await carry.listing(rig.work.path) == ["only.txt"])
        #expect(rig.shellRuns == 0)
    }

    @Test func anOlderBoxsLandingGoesByRmOverSSH() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let landing = rig.work.appendingPathComponent(".proj.kore-1a2b3c4d")
        try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
        let box = OpsBox(fsOps2: false)
        await CarryBox(alias: "box", files: box, ssh: rig.ssh).removeLanding(landing.path) { false }
        #expect(!FileManager.default.fileExists(atPath: landing.path))
        #expect(rig.shellRuns == 1 && box.asked.isEmpty)
    }

    @Test func aNewBoxsLandingGoesToItsTrash() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let landing = rig.work.appendingPathComponent(".proj.kore-1a2b3c4d")
        try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
        let box = OpsBox(fsOps2: true)
        await CarryBox(alias: "box", files: box, ssh: rig.ssh).removeLanding(landing.path) { true }
        #expect(box.asked == ["fs.delete landing \(landing.path)"])
        #expect(rig.shellRuns == 0 && FileManager.default.fileExists(atPath: landing.path))
    }

    // MARK: A real box

    @Test func aRealBoxSaysTheCapAndDeletesItself() async throws {
        let rig = try BoxRig()
        let connection = rig.connection()
        connection.retain()
        defer {
            connection.release()
            rig.finish()
        }
        #expect(await until(5) { connection.isOnline })
        #expect(connection.fsOps2)
        let work = rig.folder.path
        try FileManager.default.createDirectory(atPath: work + "/src", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: work + "/src/b.txt"))
        let never = SyncBox.via("/usr/bin/false", alias: "box", base: nil)
        #expect(await HostSync.deleteOnBox(["src/b.txt"], in: work, files: connection, box: never, low: false) == nil)
        #expect(!FileManager.default.fileExists(atPath: work + "/src"))
    }
}
