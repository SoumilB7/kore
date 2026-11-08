import Foundation
import HostClient
import KoreCore
import Testing

/// Two-way sync against a real kore-host on this Mac (its `sync.watch` on FSEvents), reached
/// through `kore-host attach` on a pipe; "the box" is a second scratch folder, its files moved
/// with rsync locally. The first copy, a Mac edit, a box edit, a delete, a conflict kept twice,
/// and no echo. Runs when kore-host is built (`KORE_HOST_BIN`, else the package's debug build).
@MainActor
@Suite(.serialized)
struct HostSyncTests {
    nonisolated static let binary: String? = {
        if let set = ProcessInfo.processInfo.environment["KORE_HOST_BIN"] { return set }
        let built = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/kore-host").path
        return FileManager.default.isExecutableFile(atPath: built) ? built : nil
    }()

    @Test func decisions() {
        let a = SyncStat(size: 1, mtime: 1), b = SyncStat(size: 2, mtime: 2), c = SyncStat(size: 3, mtime: 3)
        #expect(HostSync.decide(mac: a, box: a, agreed: nil) == .agree)
        #expect(HostSync.decide(mac: b, box: a, agreed: a) == .push)
        #expect(HostSync.decide(mac: a, box: b, agreed: a) == .pull)
        #expect(HostSync.decide(mac: nil, box: a, agreed: a) == .deleteBox)
        #expect(HostSync.decide(mac: a, box: nil, agreed: a) == .deleteMac)
        #expect(HostSync.decide(mac: b, box: c, agreed: a) == .both)
        #expect(HostSync.decide(mac: nil, box: c, agreed: a) == .pull)
        #expect(HostSync.decide(mac: nil, box: c, agreed: nil, seed: true) == .deleteBox)
    }

    @Test func ignoreRules() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kst-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, ".gitignore", "*.log\n/out/\n!keep.log\n")
        try write(root, "a.txt", "a")
        try write(root, "x.log", "x")
        try write(root, "keep.log", "k")
        try write(root, "out/o.txt", "o")
        try write(root, "deep/out/d.txt", "d")
        try write(root, "node_modules/m.js", "m")
        try write(root, "deep/.gitignore", "*.tmp\n")
        try write(root, "deep/t.tmp", "t")
        let files = Set(SyncTree(root: root).list().keys)
        #expect(files == [".gitignore", "a.txt", "keep.log", "deep/out/d.txt", "deep/.gitignore"])
    }

    @Test(.enabled(if: binary != nil))
    func twoWays() async throws {
        let bin = try #require(Self.binary)
        let root = URL(fileURLWithPath: "/tmp/kbs-\(UUID().uuidString.prefix(6))")
        let mac = root.appendingPathComponent("proj")
        let base = root.appendingPathComponent("code")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(mac, "a.txt", "one")
        try write(mac, "sub/b.txt", "two")
        try write(mac, "c.txt", "three")
        try write(mac, "debug.log", "ignored")
        try write(mac, ".gitignore", "*.log\n")
        try write(mac, "node_modules/x.js", "skipped")

        var env = ProcessInfo.processInfo.environment
        env["XDG_STATE_HOME"] = root.appendingPathComponent("state").path
        env["XDG_RUNTIME_DIR"] = root.appendingPathComponent("run").path
        env["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        let config = root.appendingPathComponent("config/kore-host/config.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["folders": [String]()]).write(to: config)
        let allow = Process()
        allow.executableURL = URL(fileURLWithPath: bin)
        allow.arguments = ["allow", "laptop", "--control", "act"]
        allow.environment = env
        try allow.run()
        allow.waitUntilExit()
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: bin)
        daemon.arguments = ["run"]
        daemon.environment = env
        try daemon.run()
        defer { daemon.terminate() }
        #expect(await until(10) { FileManager.default.fileExists(atPath: root.appendingPathComponent("run/kore-host/link.sock").path) })

        let cache = root.appendingPathComponent("cache")
        let connection = HostConnection(alias: "testbox", cache: HostCache(alias: "testbox", root: cache)) {
            SSHTransport(executable: bin, arguments: ["attach", "--as", "laptop"], environment: env)
        }
        connection.retain()
        defer { connection.release() }
        #expect(await until(10) { connection.isOnline })
        let defaults = try #require(UserDefaults(suiteName: "kore-sync-test-\(UUID().uuidString)"))
        let box = SyncBox.local(alias: "testbox", base: base.path)

        // The first copy: made, served, paired, then the files once the sync starts.
        let made = await HostSync.firstCopy(mac: mac, connection: connection, box: box, defaults: defaults)
        let pair = try made.get()
        #expect(pair.fresh == true)
        #expect(connection.folders.map(\.path).contains(pair.box))
        #expect(SyncPairs.pair(mac: mac.standardizedFileURL.path, defaults) == pair)
        let copy = URL(fileURLWithPath: pair.box)
        var sync = HostSync(pair: pair, connection: connection, box: box, root: cache, defaults: defaults)
        sync.start()
        #expect(await until(15) { read(copy, "a.txt") == "one" && read(copy, "sub/b.txt") == "two" })
        #expect(read(copy, "debug.log") == nil)
        #expect(read(copy, "node_modules/x.js") == nil)
        #expect(await until(5) { SyncPairs.pair(mac: mac.standardizedFileURL.path, defaults)?.fresh == nil })

        // The Mac's edit reaches the box, once: its echo from the box carries nothing back.
        try await settle(sync)
        let before = sync.carried
        try write(mac, "a.txt", "mac edit")
        #expect(await until(10) { read(copy, "a.txt") == "mac edit" })
        try await Task.sleep(for: .seconds(2))
        #expect(sync.carried == before + 1)

        // The box's edit reaches the Mac, once.
        try write(copy, "sub/b.txt", "box edit")
        #expect(await until(10) { read(mac, "sub/b.txt") == "box edit" })
        try await Task.sleep(for: .seconds(2))
        #expect(sync.carried == before + 2)
        #expect(read(copy, "sub/b.txt") == "box edit")

        // A delete on the Mac goes on the box.
        try FileManager.default.removeItem(at: mac.appendingPathComponent("a.txt"))
        #expect(await until(10) { read(copy, "a.txt") == nil })

        // Both sides change c.txt while the window is closed: the Mac keeps its own, the box's
        // goes beside it, and both end up on both sides.
        sync.stop()
        try write(mac, "c.txt", "mac side")
        try write(copy, "c.txt", "box side, longer")
        sync = HostSync(pair: pair, connection: connection, box: box, root: cache, defaults: defaults)
        sync.start()
        #expect(await until(15) { read(mac, "c (testbox).txt") == "box side, longer" && read(copy, "c (testbox).txt") == "box side, longer" })
        #expect(read(mac, "c.txt") == "mac side")
        #expect(await until(5) { read(copy, "c.txt") == "mac side" })
        #expect(await until(5) { sync.notice?.contains("Kept both") == true })
        sync.stop()
    }

    /// On a real box, run on purpose only: `KORE_SYNC_BOX=<alias>` (and `KORE_SYNC_GRANT`, a grant
    /// there). Makes `~/Code/kore-sync-check` there, edits each way, and leaves the copy for the
    /// caller to remove.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KORE_SYNC_BOX"] != nil))
    func realBox() async throws {
        let env = ProcessInfo.processInfo.environment
        let alias = try #require(env["KORE_SYNC_BOX"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ksr-\(UUID().uuidString.prefix(6))")
        let mac = root.appendingPathComponent("kore-sync-check")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(mac, "a.txt", "one")
        try write(mac, "sub/b.txt", "two")
        let connection = HostConnection(alias: alias, grant: env["KORE_SYNC_GRANT"] ?? HostConnection.defaultGrant, cache: HostCache(alias: alias, root: root.appendingPathComponent("cache")))
        connection.retain()
        defer { connection.release() }
        #expect(await until(30) { connection.isOnline })
        let defaults = try #require(UserDefaults(suiteName: "kore-sync-real-\(UUID().uuidString)"))
        let box = SyncBox.ssh(alias)
        #expect(await HostSync.preflight(mac: mac, box: box) == .go)
        let pair = try await HostSync.firstCopy(mac: mac, connection: connection, box: box, defaults: defaults).get()
        print("real box copy: \(pair.box)")
        let sync = HostSync(pair: pair, connection: connection, box: box, root: root.appendingPathComponent("cache"), defaults: defaults)
        sync.start()
        func remote(_ path: String) async -> String? {
            let out = await box.shell("cat " + SyncProcess.quoted(pair.box + "/" + path), nil, false)
            return out.status == 0 ? out.out : nil
        }
        var copied = false
        for _ in 0..<40 where !copied {
            copied = await remote("sub/b.txt") == "two"
            if !copied { try await Task.sleep(for: .milliseconds(500)) }
        }
        #expect(copied)
        try write(mac, "a.txt", "mac edit")
        var pushed = false
        for _ in 0..<40 where !pushed {
            pushed = await remote("a.txt") == "mac edit"
            if !pushed { try await Task.sleep(for: .milliseconds(500)) }
        }
        #expect(pushed)
        _ = await box.shell("printf 'box edit' > " + SyncProcess.quoted(pair.box + "/sub/b.txt"), nil, false)
        #expect(await until(20) { read(mac, "sub/b.txt") == "box edit" })
        print("real box: watching \(sync.boxWatches) carried \(sync.carried) rounds \(sync.rounds) notice \(sync.notice ?? "-")")
        sync.stop()
    }

    // MARK: Helpers

    private func settle(_ sync: HostSync) async throws {
        var last = -1
        while last != sync.rounds {
            last = sync.rounds
            try await Task.sleep(for: .seconds(1))
        }
    }

    private func write(_ root: URL, _ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Another second, so a rewrite within the same second still reads as a change (whole-second mtimes).
        let old = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        try Data(text.utf8).write(to: url)
        if let old, Date().timeIntervalSince1970.rounded(.down) <= old.timeIntervalSince1970.rounded(.down) {
            try FileManager.default.setAttributes([.modificationDate: old.addingTimeInterval(1)], ofItemAtPath: url.path)
        }
    }

    private func read(_ root: URL, _ path: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }
}
