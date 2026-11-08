import Foundation
import HostClient
import KoreCore
import Testing

/// Two-way sync against a real kore-host on this Mac (its `sync.watch` on FSEvents), reached
/// through `kore-host attach` on a pipe; "the box" is a second scratch folder. Every remote command
/// and rsync path goes through a stand-in ssh that hands the command to `sh -c`, as sshd's shell
/// would, so quoting is tested for real. Runs when kore-host is built (`KORE_HOST_BIN`, else the
/// package's debug build).
@MainActor
@Suite(.serialized)
struct HostSyncTests {
    nonisolated static let binary: String? = {
        if let set = ProcessInfo.processInfo.environment["KORE_HOST_BIN"] { return set }
        let built = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/kore-host").path
        return FileManager.default.isExecutableFile(atPath: built) ? built : nil
    }()

    // MARK: Without a box

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
        let root = scratch("kst")
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

    /// What a box may name: relative, plain parts, no control characters.
    @Test func boxPaths() {
        for bad in ["", "/etc/passwd", "../x", "a/../../x", "a//b", "./a", "a/.", "a/", "a\0b", "a\nb", "a\u{1b}b",
                    "../../Library/LaunchAgents/com.google.keystone.agent.plist"] {
            #expect(!SyncPath.valid(bad), "\(bad)")
        }
        for good in ["a.txt", "sub/b.txt", "-rf", "it's $(touch x).md", "ünïcode/名前.txt", ".env", "a..b"] {
            #expect(SyncPath.valid(good), "\(good)")
        }
    }

    /// A path through a link inside the folder is neither read nor written, whatever the box says.
    @Test func linkedFolders() throws {
        let root = scratch("ksl")
        defer { try? FileManager.default.removeItem(at: root) }
        let mac = root.appendingPathComponent("mac"), outside = root.appendingPathComponent("outside")
        try write(outside, "secret.txt", "s")
        try write(mac, "a.txt", "a")
        try FileManager.default.createSymbolicLink(at: mac.appendingPathComponent("docs"), withDestinationURL: outside)
        let tree = SyncTree(root: mac)
        #expect(!tree.plain("docs/secret.txt"))
        #expect(tree.stat("docs/secret.txt") == nil)
        #expect(tree.list(at: "docs").isEmpty)
        #expect(tree.list().keys.sorted() == ["a.txt"])
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let round = SyncRound(tree: tree, manifest: SyncManifest(url: work.appendingPathComponent("m.tsv")), scratch: work, alias: "box", caseless: true)
        let plan = round.changes(mac: [], box: ["docs/secret.txt": SyncStat(size: 9, mtime: 9), "docs/new.txt": SyncStat(size: 1, mtime: 1)])
        #expect(plan.pulls == 0 && plan.both.isEmpty && plan.deleteMac.isEmpty)
        #expect(plan.skippedLinks)
    }

    /// Two box names that differ only by case are left alone on a Mac that ignores case.
    @Test func caseClash() throws {
        let root = scratch("ksc")
        defer { try? FileManager.default.removeItem(at: root) }
        let mac = root.appendingPathComponent("mac"), work = root.appendingPathComponent("work")
        try write(mac, "other.txt", "o")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let list = work.appendingPathComponent("box.tsv")
        try Data("Foo.swift\t1\t1\nfoo.swift\t2\t2\nother.txt\t1\t1\n".utf8).write(to: list)
        let round = SyncRound(tree: SyncTree(root: mac), manifest: SyncManifest(url: work.appendingPathComponent("m.tsv")), scratch: work, alias: "box", caseless: true)
        let plan = round.whole(boxFile: list, seed: false)
        #expect(plan.clash == "Foo.swift and foo.swift")
        #expect(plan.pulls == 0)
    }

    /// Names and paths reach the box's shell as words, never as script text.
    @Test func shellWords() async throws {
        let root = scratch("ksw")
        defer { try? FileManager.default.removeItem(at: root) }
        let box = try fakeBox(root, base: root.appendingPathComponent("code"))
        let out = root.appendingPathComponent("out.txt")
        let hostile = "$(touch \(root.path)/pwned)'\"`id` -rf é"
        let said = await box.shell("printf %s \"$1\" > \"$2\"", [hostile, out.path])
        #expect(said.status == 0)
        #expect(read(root, "out.txt") == hostile)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("pwned").path))
        #expect(HostSync.boxName(URL(fileURLWithPath: "/x/$(touch y) it's")) == "folder--touch-y--it-s")
        #expect(HostSync.boxName(URL(fileURLWithPath: "/x/.hidden")) == "folder.hidden")
        #expect(!HostSync.safeOrigin("-uhack") && !HostSync.safeOrigin("ext::sh -c id") && HostSync.safeOrigin("git@github.com:a/b.git"))
        #expect(!SyncBox.validAlias("-oProxyCommand=x") && !SyncBox.validAlias("a:b") && !SyncBox.validAlias("a b") && SyncBox.validAlias("my-box.lan"))
    }

    // MARK: With a box

    @Test(.enabled(if: binary != nil))
    func twoWays() async throws {
        let rig = try await Rig(Self.binary!)
        defer { rig.end() }
        let mac = rig.root.appendingPathComponent("proj")
        try write(mac, "a.txt", "one")
        try write(mac, "sub/b.txt", "two")
        try write(mac, "c.txt", "three")
        try write(mac, "debug.log", "ignored")
        try write(mac, ".gitignore", "*.log\n")
        try write(mac, "node_modules/x.js", "skipped")
        // Names a shell would read as code, a quote, an option, a space, unicode.
        let odd = ["it's $(touch PWNED) x.md", "-rf", "ünï code.txt", "q\"uote`s`.txt"]
        for name in odd { try write(mac, name, name) }

        // The first copy: made, served, paired, then the files once the sync starts.
        let pair = try await rig.copy(mac)
        #expect(pair.fresh == true)
        #expect(rig.connection.folders.map(\.path).contains(pair.box))
        #expect(SyncPairs.pair(mac: mac.standardizedFileURL.path, rig.defaults) == pair)
        let copy = URL(fileURLWithPath: pair.box)
        var sync = try rig.sync(pair)
        #expect(await until(15) { read(copy, "a.txt") == "one" && read(copy, "sub/b.txt") == "two" && odd.allSatisfy { read(copy, $0) == $0 } })
        #expect(read(copy, "debug.log") == nil)
        #expect(read(copy, "node_modules/x.js") == nil)
        #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent("PWNED").path))
        #expect(!FileManager.default.fileExists(atPath: mac.appendingPathComponent("PWNED").path))
        #expect(await until(5) { SyncPairs.pair(mac: mac.standardizedFileURL.path, rig.defaults)?.fresh == nil })

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

        // A delete on the Mac goes on the box.
        try FileManager.default.removeItem(at: mac.appendingPathComponent("a.txt"))
        #expect(await until(10) { read(copy, "a.txt") == nil })

        // A rename that changes only case on the box is a rename on the Mac, never a delete.
        try FileManager.default.moveItem(at: copy.appendingPathComponent("c.txt"), to: copy.appendingPathComponent("C.txt"))
        #expect(await until(10) { (try? FileManager.default.contentsOfDirectory(atPath: mac.path))?.contains("C.txt") == true })
        try await settle(sync)
        #expect(read(mac, "C.txt") == "three" && read(copy, "C.txt") == "three")

        // A newly ignored folder stops syncing and is deleted on neither side, a whole round included.
        try write(mac, "data/keep.csv", "1,2")
        #expect(await until(10) { read(copy, "data/keep.csv") == "1,2" })
        try write(mac, ".gitignore", "*.log\ndata/\n")
        #expect(await until(10) { read(copy, ".gitignore") == "*.log\ndata/\n" })
        try await settle(sync)
        sync.stop()
        sync = try rig.sync(pair)
        try await settle(sync)
        #expect(read(mac, "data/keep.csv") == "1,2" && read(copy, "data/keep.csv") == "1,2")

        // Both sides change one file while the window is closed: the Mac keeps its own, the box's
        // goes beside it, and both end up on both sides.
        sync.stop()
        try write(mac, "C.txt", "mac side")
        try write(copy, "C.txt", "box side, longer")
        sync = try rig.sync(pair)
        #expect(await until(15) { read(mac, "C (testbox).txt") == "box side, longer" && read(copy, "C (testbox).txt") == "box side, longer" })
        #expect(read(mac, "C.txt") == "mac side")
        #expect(await until(5) { read(copy, "C.txt") == "mac side" })
        #expect(await until(5) { sync.notice?.contains("Kept both") == true })
        sync.stop()
    }

    /// A missing or emptied side, or a bulk delete, stops the round: nothing goes on the other side
    /// until the user says so.
    @Test(.enabled(if: binary != nil))
    func noBulkDeletes() async throws {
        let rig = try await Rig(Self.binary!)
        defer { rig.end() }
        let mac = rig.root.appendingPathComponent("many")
        for i in 0..<20 { try write(mac, "f\(i).txt", "\(i)") }
        let pair = try await rig.copy(mac)
        let copy = URL(fileURLWithPath: pair.box)
        var sync = try rig.sync(pair)
        #expect(await until(15) { read(copy, "f19.txt") == "19" })
        try await settle(sync)
        sync.stop()

        // The box copy is gone: the Mac keeps everything.
        let aside = rig.root.appendingPathComponent("aside")
        try FileManager.default.moveItem(at: copy, to: aside)
        sync = try rig.sync(pair)
        #expect(await until(10) { sync.notice?.contains("missing on testbox") == true })
        #expect(read(mac, "f0.txt") == "0" && read(mac, "f19.txt") == "19")
        sync.stop()

        // The box copy is there but empty: the same.
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        sync = try rig.sync(pair)
        #expect(await until(10) { sync.notice?.contains("is empty on testbox") == true })
        #expect(read(mac, "f0.txt") == "0" && read(mac, "f19.txt") == "19")
        sync.stop()
        try FileManager.default.removeItem(at: copy)
        try FileManager.default.moveItem(at: aside, to: copy)

        // Twelve of twenty go on the box: asked first, then done once allowed.
        for i in 0..<12 { try FileManager.default.removeItem(at: copy.appendingPathComponent("f\(i).txt")) }
        sync = try rig.sync(pair)
        #expect(await until(10) { sync.askDeletes == 12 })
        #expect(read(mac, "f0.txt") == "0")
        sync.allowDeletes()
        #expect(await until(10) { read(mac, "f0.txt") == nil && read(mac, "f11.txt") == nil })
        #expect(read(mac, "f12.txt") == "12")
        sync.stop()
    }

    /// Two Mac folders with one name get two box copies; a retry after a failed first round keeps
    /// what box chats made meanwhile.
    @Test(.enabled(if: binary != nil))
    func copiesAndRetries() async throws {
        let rig = try await Rig(Self.binary!)
        defer { rig.end() }
        let first = rig.root.appendingPathComponent("work/app"), second = rig.root.appendingPathComponent("home/app")
        try write(first, "w.txt", "work")
        try write(second, "h.txt", "home")
        let one = try await rig.copy(first), two = try await rig.copy(second)
        #expect(one.box.hasSuffix("/app") && two.box.hasSuffix("/app-2"))
        #expect(SyncPairs.pair(mac: second.standardizedFileURL.path, rig.defaults)?.box == two.box)

        // As after a first round that failed: no agreed list, no seed. A box chat made a file and
        // changed one the Mac has too.
        var retry = two
        retry.fresh = nil
        SyncPairs.save(retry, rig.defaults)
        let copy = URL(fileURLWithPath: two.box)
        try write(copy, "agent.txt", "made on the box")
        try write(copy, "h.txt", "box version")
        let sync = try rig.sync(retry)
        #expect(await until(15) { read(second, "agent.txt") == "made on the box" })
        #expect(await until(10) { read(second, "h (testbox).txt") == "box version" })
        #expect(read(second, "h.txt") == "home")
        #expect(read(copy, "agent.txt") == "made on the box")
        sync.stop()
    }

    /// On a real box, run on purpose only: `KORE_SYNC_BOX=<alias>` (and `KORE_SYNC_GRANT`, a grant
    /// there). Makes `~/Code/kore-sync-check` there, edits each way, and leaves the copy for the
    /// caller to remove.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KORE_SYNC_BOX"] != nil))
    func realBox() async throws {
        let env = ProcessInfo.processInfo.environment
        let alias = try #require(env["KORE_SYNC_BOX"])
        let root = scratch("ksr")
        let mac = root.appendingPathComponent("kore-sync-check")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(mac, "a.txt", "one")
        try write(mac, "sub/b.txt", "two")
        try write(mac, "it's $(touch PWNED) x.md", "odd")
        let connection = HostConnection(alias: alias, grant: env["KORE_SYNC_GRANT"] ?? HostConnection.defaultGrant, cache: HostCache(alias: alias, root: root.appendingPathComponent("cache")))
        connection.retain()
        defer { connection.release() }
        let defaults = try #require(UserDefaults(suiteName: "kore-sync-real-\(UUID().uuidString)"))
        let box = try #require(SyncBox.ssh(alias))
        #expect(await HostSync.preflight(mac: mac, box: box) == .go)
        let pair = try await HostSync.firstCopy(mac: mac, connection: connection, box: box, defaults: defaults).get()
        print("real box copy: \(pair.box)")
        let sync = try #require(HostSync(pair: pair, connection: connection, box: box, root: root.appendingPathComponent("cache"), defaults: defaults))
        sync.start()
        func remote(_ path: String) async -> String? {
            let out = await box.shell("cat -- \"$1/$2\"", [pair.box, path])
            return out.status == 0 ? out.out : nil
        }
        var copied = false
        for _ in 0..<40 where !copied {
            copied = await remote("sub/b.txt") == "two"
            if copied { copied = await remote("it's $(touch PWNED) x.md") == "odd" }
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
        _ = await box.shell("printf 'box edit' > \"$1/sub/b.txt\"", [pair.box])
        #expect(await until(20) { read(mac, "sub/b.txt") == "box edit" })
        print("real box: watching \(sync.boxWatches) carried \(sync.carried) rounds \(sync.rounds) notice \(sync.notice ?? "-")")
        sync.stop()
    }

    // MARK: The rig

    /// A kore-host daemon in a scratch folder, a connection to it over `attach`, and a stand-in
    /// ssh for the "box" (this Mac).
    @MainActor
    final class Rig {
        let root: URL
        let connection: HostConnection
        let defaults: UserDefaults
        let box: SyncBox
        let cache: URL
        private let daemon: Process

        init(_ bin: String) async throws {
            root = URL(fileURLWithPath: "/tmp/kbs-\(UUID().uuidString.prefix(6))")
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
            daemon = Process()
            daemon.executableURL = URL(fileURLWithPath: bin)
            daemon.arguments = ["run"]
            daemon.environment = env
            try daemon.run()
            let socket = root.appendingPathComponent("run/kore-host/link.sock").path
            #expect(await until(10) { FileManager.default.fileExists(atPath: socket) })
            cache = root.appendingPathComponent("cache")
            connection = HostConnection(alias: "testbox", cache: HostCache(alias: "testbox", root: cache)) {
                SSHTransport(executable: bin, arguments: ["attach", "--as", "laptop"], environment: env)
            }
            connection.retain()
            let connection = connection
            #expect(await until(10) { connection.isOnline })
            defaults = UserDefaults(suiteName: "kore-sync-test-\(UUID().uuidString)")!
            box = try fakeBox(root, base: root.appendingPathComponent("code"))
        }

        func copy(_ mac: URL) async throws -> SyncPair {
            try await HostSync.firstCopy(mac: mac, connection: connection, box: box, defaults: defaults).get()
        }

        func sync(_ pair: SyncPair) throws -> HostSync {
            let sync = try #require(HostSync(pair: pair, connection: connection, box: box, root: cache, defaults: defaults))
            sync.start()
            return sync
        }

        func end() {
            connection.release()
            daemon.terminate()
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: Helpers

    private func settle(_ sync: HostSync) async throws {
        var last = -1
        while last != sync.rounds {
            last = sync.rounds
            try await Task.sleep(for: .seconds(1))
        }
    }
}

/// A scratch folder; short, so a socket path inside fits.
private func scratch(_ prefix: String) -> URL {
    URL(fileURLWithPath: "/tmp/\(prefix)-\(UUID().uuidString.prefix(6))")
}

/// "The box" on this Mac through a stand-in ssh: everything after `--` and the alias is run by
/// `sh -c`, as sshd hands a command to the login shell.
private func fakeBox(_ root: URL, base: URL) throws -> SyncBox {
    let ssh = root.appendingPathComponent("fake-ssh")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("""
        #!/bin/sh
        while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
        shift; shift
        exec /bin/sh -c "$*"
        """.utf8).write(to: ssh)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
    return SyncBox.via(ssh.path, alias: "testbox", base: base.path)
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
