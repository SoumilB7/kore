import Foundation
@testable import HostClient
import KoreCore
@testable import KoreHost
import LinkProtocol
import Testing

/// A sync's rsync lists go in batches of `SyncBatch.size` (openrsync stalls on a long
/// `--files-from`), and a carry's landing never syncs. No network, no rsync: a stand-in runs each
/// batch and says what rsync would.
@Suite("sync batches and landings")
@MainActor
struct SyncBatchTests {
    /// What each batch held, as the stand-in saw it while it ran.
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [(count: Int, lines: [String], url: URL)] = []
        private var argvs: [[String]] = []

        func add(_ url: URL, _ count: Int) {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let lines = text.split(separator: "\n").map(String.init)
            lock.withLock { batches.append((count, lines, url)) }
        }

        func add(argv: [String]) {
            let list = argv.first { $0.hasPrefix("--files-from=") }.map { URL(fileURLWithPath: String($0.dropFirst("--files-from=".count))) }
            lock.withLock { argvs.append(argv) }
            if let list { add(list, 0) }
        }

        var counts: [Int] { lock.withLock { batches.map(\.count) } }
        var lines: [[String]] { lock.withLock { batches.map(\.lines) } }
        var urls: [URL] { lock.withLock { batches.map(\.url) } }
        var commands: [[String]] { lock.withLock { argvs } }
    }

    // MARK: Batches

    @Test func listsSplitAtTheBatchSize() async throws {
        #expect(SyncBatch.size == 5_000)
        let root = tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        for (paths, expected) in [(0, [Int]()), (5_000, [5_000]), (5_001, [5_000, 1]), (12_345, [5_000, 5_000, 2_345])] {
            let list = try writeList(root, (0..<paths).map { "dir \($0 % 7)/f\($0).txt" })
            let seen = Seen()
            let done = try await SyncBatch.each(list, in: root) { url, count in
                seen.add(url, count)
                return true
            }
            #expect(done)
            #expect(seen.counts == expected, "\(paths) paths")
            #expect(seen.lines.map(\.count) == expected)
            // Every path once, in order, and no batch file left behind.
            #expect(seen.lines.flatMap { $0 } == (0..<paths).map { "dir \($0 % 7)/f\($0).txt" })
            #expect(seen.urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            #expect(batchFiles(root).isEmpty)
        }
    }

    @Test func aLastLineWithoutItsNewlineCounts() async throws {
        let root = tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let list = root.appendingPathComponent("list.txt")
        try Data("a\nb\nc".utf8).write(to: list)
        let seen = Seen()
        #expect(try await SyncBatch.each(list, in: root, size: 2) { url, count in
            seen.add(url, count)
            return true
        })
        #expect(seen.counts == [2, 1])
        #expect(seen.lines == [["a", "b"], ["c"]])
    }

    /// A batch that fails ends the list there: none after it runs, none of its files stay.
    @Test func aFailedBatchStopsTheRest() async throws {
        let root = tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let list = try writeList(root, (0..<12_000).map { "f\($0)" })
        let seen = Seen()
        let done = try await SyncBatch.each(list, in: root) { url, count in
            seen.add(url, count)
            return seen.counts.count < 2
        }
        #expect(!done)
        #expect(seen.counts == [5_000, 5_000])
        #expect(batchFiles(root).isEmpty)
    }

    @Test func aListThatCantBeReadThrows() async {
        let root = tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) {
            try await SyncBatch.each(root.appendingPathComponent("missing.txt"), in: root) { _, _ in true }
        }
    }

    /// A whole round with more pulls than a batch: one rsync per batch, each with its own list and
    /// both ends' timeouts. The second fails: the third never runs, the agreed list stays as it
    /// was, and the round says why.
    @Test func aRoundRunsABatchAtATimeAndAFailureKeepsTheAgreedList() async throws {
        let rig = try SyncRig()
        defer { rig.end() }
        let seen = Seen()
        rig.sync.batch = 2
        rig.sync.runRsync = { argv, _ in
            seen.add(argv: argv)
            return seen.commands.count == 2
                ? SyncProcess.Output(status: 10, out: "", err: "rsync: poll: timeout")
                : SyncProcess.Output(status: 0, out: "", err: "")
        }
        let before = try Data(contentsOf: rig.manifest)
        await rig.sync.whole(try rig.boxList())
        #expect(seen.commands.count == 2)
        #expect(seen.lines == [["p1.txt", "p2.txt"], ["p3.txt", "p4.txt"]])
        for argv in seen.commands {
            #expect(argv.filter { $0.hasPrefix("--files-from=") }.count == 1)
            #expect(argv.contains("--timeout=60"))
            #expect(argv.contains("--rsync-path=nice -n 10 rsync --timeout=120"))
            #expect(argv.suffix(2) == ["testbox:'\(rig.boxPath)/'", rig.mac.path + "/"])
        }
        #expect(seen.urls[0] != seen.urls[1])
        #expect(try Data(contentsOf: rig.manifest) == before)
        #expect(rig.sync.notice == "Sync paused: rsync: poll: timeout")
        // The first batch went: it counts.
        #expect(rig.sync.carried == 2)
        #expect(batchFiles(rig.scratch).isEmpty)
    }

    /// All batches go: the agreed list takes the round, landings left out.
    @Test func aRoundThatGoesWholeKeepsItsAgreedList() async throws {
        let rig = try SyncRig()
        defer { rig.end() }
        let seen = Seen()
        rig.sync.batch = 2
        rig.sync.runRsync = { argv, _ in
            seen.add(argv: argv)
            return SyncProcess.Output(status: 0, out: "", err: "")
        }
        await rig.sync.whole(try rig.boxList())
        #expect(seen.lines == [["p1.txt", "p2.txt"], ["p3.txt", "p4.txt"], ["p5.txt"]])
        #expect(rig.sync.carried == 5 && rig.sync.notice == nil)
        let agreed = try String(contentsOf: rig.manifest, encoding: .utf8).split(separator: "\n").map { String($0.split(separator: "\t")[0]) }
        #expect(agreed == ["keep.txt", "p1.txt", "p2.txt", "p3.txt", "p4.txt", "p5.txt"])
    }

    // MARK: Landings

    @Test func landingNames() {
        for name in [".kore-copy-1234", ".NCDEX.kore-48d6709b", ".a b.kore-ABCDEF01", ".x.tar.kore-00000000"] {
            #expect(SyncPath.isLanding(name), "\(name)")
            #expect(LinkFsOps.isLanding(name), "\(name)")
        }
        for name in ["NCDEX.kore-48d6709b", ".NCDEX.kore-48d6709", ".NCDEX.kore-48d6709bb", ".NCDEX.kore-48d6709g", ".kore-copy", "kore-copy-1", ".env"] {
            #expect(!SyncPath.isLanding(name), "\(name)")
            #expect(!LinkFsOps.isLanding(name), "\(name)")
        }
        #expect(SyncPath.inLanding(".NCDEX.kore-48d6709b/data/x.csv"))
        #expect(SyncPath.inLanding("deep/.kore-copy-9/x"))
        #expect(!SyncPath.inLanding("NCDEX/data/x.csv"))
    }

    /// The Mac's scan and the box's list (the same tree walks, `sync.watch`'s whole list and its
    /// changes) never name a landing or what's in it.
    @Test func scansLeaveLandingsOut() throws {
        let root = tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "a.txt", "a")
        try write(root, "NCDEX/n.csv", "n")
        try write(root, ".NCDEX.kore-48d6709b/n.csv", "half")
        try write(root, "deep/.kore-copy-77/x.bin", "x")
        try write(root, "deep/.report.pdf.kore-0a1b2c3d", "file landing")
        try write(root, ".x.kore-1234567/kept.txt", "7 hex: not a landing")
        let kept: Set<String> = ["a.txt", "NCDEX/n.csv", ".x.kore-1234567/kept.txt"]
        let tree = SyncTree(root: root)
        #expect(Set(tree.list().keys) == kept)
        #expect(Set(try #require(tree.list(cap: 100)).keys) == kept)
        let scan = tree.scan(fileCap: 100, folderCap: 100)
        #expect(Set(try #require(scan.files).keys) == kept)
        #expect(!scan.folders.contains { SyncPath.inLanding($0) })
        #expect(tree.ignored(".NCDEX.kore-48d6709b/n.csv") && tree.ignored(".NCDEX.kore-48d6709b"))
        #expect(tree.stat(".NCDEX.kore-48d6709b/n.csv") == nil && tree.list(at: ".NCDEX.kore-48d6709b").isEmpty)
        // The box's whole list, and a change inside a landing: nothing of it goes.
        let all = SyncWatch.all(tree.list(cap: SyncWatch.fileCap), folder: root.path, watching: (on: true, limit: nil, folders: nil))
        let named = all.flatMap { HostWire.syncChanged($0)?.paths.map(\.p) ?? [] }
        #expect(Set(named) == kept)
        #expect(SyncWatch.changes([".NCDEX.kore-48d6709b/n.csv", "deep/.kore-copy-77/x.bin"], tree: tree, folder: root.path).isEmpty)
    }

    /// An older box's shell count leaves landings out too.
    @Test func theBoxsShellCountLeavesLandingsOut() async throws {
        let root = tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "a.txt", "a")
        try write(root, ".NCDEX.kore-48d6709b/n.csv", "half")
        try write(root, "deep/.kore-copy-77/x.bin", "x")
        try write(root, "deep/.r.pdf.kore-0a1b2c3d", "x")
        try write(root, "deep/b.txt", "b")
        let said = await SyncProcess.run("/bin/sh", ["-c", HostSync.boxCountScript, "sh", root.path])
        #expect(said.out.split(separator: " ").first == "2")
    }

    /// The plan: an older box's list naming landings, and a change inside one, carry and delete
    /// nothing, and the agreed list drops them.
    @Test func plansLeaveLandingsOut() throws {
        let root = tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let mac = root.appendingPathComponent("mac"), work = root.appendingPathComponent("work")
        try write(mac, "a.txt", "a")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let manifest = work.appendingPathComponent("m.tsv")
        try Data(".old.kore-0a1b2c3d/z.txt\t1\t1\n".utf8).write(to: manifest)
        let list = work.appendingPathComponent("box.tsv")
        try Data(".NCDEX.kore-48d6709b/n.csv\t4\t4\n.kore-copy-1/y.txt\t1\t1\nb.txt\t1\t1\n.old.kore-0a1b2c3d/z.txt\t1\t1\n".utf8).write(to: list)
        let round = SyncRound(tree: SyncTree(root: mac), manifest: SyncManifest(url: manifest), scratch: work, alias: "box", caseless: false)
        let plan = round.whole(boxFile: list, seed: false)
        #expect(try String(contentsOf: plan.pullList, encoding: .utf8) == "b.txt\n")
        #expect(try String(contentsOf: plan.pushList, encoding: .utf8) == "a.txt\n")
        #expect(plan.deleteMac.isEmpty && plan.deleteBox.isEmpty && plan.both.isEmpty)
        let agreed = try String(contentsOf: plan.agreedFile, encoding: .utf8)
        #expect(!agreed.contains(".kore-"))
        let changes = round.changes(mac: [".NCDEX.kore-48d6709b/n.csv"], box: [".NCDEX.kore-48d6709b/n.csv": SyncStat(size: 9, mtime: 9), ".old.kore-0a1b2c3d/z.txt": nil])
        #expect(changes.pulls == 0 && changes.pushes == 0 && changes.deleteMac.isEmpty && changes.deleteBox.isEmpty && changes.updates.isEmpty)
    }

    // MARK: Rig

    /// A pair's sync with its box offline (nothing dials): the Mac folder has `keep.txt`, agreed
    /// with the box; the box's list adds five files and two landings.
    @MainActor
    final class SyncRig {
        let root = tempFolder()
        let mac: URL
        let boxPath = "/home/me/Code/app"
        let sync: HostSync
        let manifest: URL
        let scratch: URL
        let defaults: UserDefaults
        private let suite = "kore-sync-batch-\(UUID().uuidString)"

        init() throws {
            mac = root.appendingPathComponent("mac")
            try write(mac, "keep.txt", "k")
            defaults = UserDefaults(suiteName: suite)!
            let pair = SyncPair(mac: mac.path, alias: "testbox", box: boxPath)
            let cache = root.appendingPathComponent("cache")
            let connection = HostConnection(alias: "testbox", cache: HostCache(alias: "testbox", root: cache)) { Offline() }
            sync = try #require(HostSync(pair: pair, connection: connection, box: SyncBox.via("/usr/bin/false", alias: "testbox", base: nil), root: cache, defaults: defaults))
            let files = HostSync.files(pair, root: cache)
            manifest = files.manifest
            scratch = files.scratch
            sync.start()
            try Data("keep.txt\t\(keep.size)\t\(keep.mtime)\n".utf8).write(to: manifest)
        }

        var keep: SyncStat { SyncTree(root: mac).stat("keep.txt")! }

        func boxList() throws -> URL {
            let list = scratch.appendingPathComponent("box-\(UUID().uuidString).tsv")
            let lines = ["keep.txt\t\(keep.size)\t\(keep.mtime)", ".NCDEX.kore-48d6709b/n.csv\t4\t4", ".kore-copy-1/y.txt\t1\t1"]
                + (1...5).map { "p\($0).txt\t\($0)\t\($0)" }
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: list)
            return list
        }

        func end() {
            sync.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A box that never answers.
    final class Offline: HostTransport, @unchecked Sendable {
        let events = AsyncStream<TransportEvent> { $0.finish() }
        struct Down: Error {}
        func start() throws { throw Down() }
        func send(_ payload: Data) {}
        func close() {}
    }
}

private func tempFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ksb-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeList(_ root: URL, _ paths: [String]) throws -> URL {
    let list = root.appendingPathComponent("list-\(UUID().uuidString).txt")
    try Data(paths.map { $0 + "\n" }.joined().utf8).write(to: list)
    return list
}

private func batchFiles(_ root: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix("batch-") }
}

private func write(_ root: URL, _ path: String, _ text: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}
