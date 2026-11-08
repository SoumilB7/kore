import Foundation
@testable import HostClient
import KoreCore
@testable import KoreHost
import LinkProtocol
import Testing

/// Sync rounds over one held connection, gathers that widen while changes keep coming, the noisy
/// files left out by default, and syncs that keep running with no window. No network: the box is
/// a scratch folder behind a stand-in ssh that keeps a master's socket the way ssh does, and
/// counts each connection it makes. Gathers run on a clock of their own.
@Suite("sync efficiency")
@MainActor
struct SyncEfficiencyTests {
    // MARK: Gathers

    @Test func gatherWidensWhileChangesKeepComingAndReturnsWhenQuiet() {
        var gather = SyncGather()
        #expect(gather.delay(at: 0) == 0.3)
        gather.sent(at: 0.3)
        // The next change lands before 0.3 s passed: 2 s, then 5 s, and 5 s stays the widest.
        #expect(gather.delay(at: 0.4) == 2)
        gather.sent(at: 2.4)
        #expect(gather.delay(at: 2.5) == 5)
        gather.sent(at: 7.5)
        #expect(gather.delay(at: 7.6) == 5)
        gather.sent(at: 12.6)
        // Quiet for as long as the gather: back to 0.3 s.
        #expect(gather.delay(at: 17.6) == 0.3)
        gather.sent(at: 17.9)
        // A gap of 2 s or more after a 2 s gather is quiet too.
        #expect(gather.delay(at: 18.0) == 2)
        gather.sent(at: 20.0)
        #expect(gather.delay(at: 22.0) == 0.3)
    }

    @Test func boxWatchGathersFromItsSettle() {
        let watch = SyncWatch(folder: "/nonexistent", settle: 0.05) { _ in }
        #expect(watch.gather.steps == [0.05, 2, 5])
        #expect(watch.gather.current == 0.05)
    }

    // MARK: Default skips

    @Test func noisyFilesAreLeftOutAndAFolderTakesThemBack() throws {
        let root = scratch("kse")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["a.swift", "build", "notes.md", "debug.log", "x.tmp", "a.swp", "main.swift~", ".#lock", "m.pyc", "Thumbs.db",
                     "build/out.o", "dist/app.js", "src/__pycache__/m.cpython.pyc", ".venv/bin/python", ".cache/x", "DerivedData/y",
                     ".next/z", "src/build/keep.txt"] {
            if path == "build" { continue }
            try write(root, path, path)
        }
        try write(root, "scripts/build", "#!/bin/sh")
        let tree = SyncTree(root: root)
        #expect(Set(tree.list().keys) == ["a.swift", "notes.md", "scripts/build"])
        // The root's .koresync takes build output and logs back, for this folder only.
        try write(root, ".koresync", "!build/\n!*.log\n")
        tree.forget(".koresync")
        #expect(Set(tree.list().keys) == ["a.swift", "notes.md", "scripts/build", ".koresync", "build/out.o", "src/build/keep.txt", "debug.log"])
    }

    /// An older box lists its noisy files: none comes here, and none is deleted there.
    @Test func olderBoxNoisyFilesNeverPulled() throws {
        let root = scratch("ksp")
        defer { try? FileManager.default.removeItem(at: root) }
        let mac = root.appendingPathComponent("mac"), work = root.appendingPathComponent("work")
        try write(mac, "a.txt", "a")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let list = work.appendingPathComponent("box.tsv")
        try Data("a.txt\t1\t\(mtime(mac, "a.txt"))\nserver.log\t9\t9\ndist/app.js\t3\t3\nnew.txt\t2\t2\n".utf8).write(to: list)
        let round = SyncRound(tree: SyncTree(root: mac), manifest: SyncManifest(url: work.appendingPathComponent("m.tsv")), scratch: work, alias: "box", caseless: true)
        let plan = round.whole(boxFile: list, seed: false)
        #expect(plan.pulls == 1)
        #expect(String(decoding: try Data(contentsOf: plan.pullList), as: UTF8.self) == "new.txt\n")
        #expect(plan.deleteBox.isEmpty)
    }

    // MARK: One connection

    /// Rounds through the held connection: one connection for all of them; without it, one each.
    @Test func roundsShareOneConnection() async throws {
        for held in [true, false] {
            let rig = try Rig()
            defer { rig.end() }
            rig.sync.heldConnection = held
            rig.sync.start()
            for i in 0..<4 {
                try write(rig.mac, "f\(i).txt", "\(i)")
                await rig.sync.whole(try rig.boxList())
                #expect(read(rig.box, "f\(i).txt") == "\(i)")
            }
            let log = rig.log()
            #expect(log.filter { $0 == "connect" }.count == (held ? 1 : 4), "held \(held): \(log)")
            #expect(log.filter { $0 == "mux" }.count == (held ? 4 : 0))
            if held {
                // Stopping ends the master: its remote cat reads Kore's pipe closing.
                let socket = try #require(rig.sync.channel?.socket)
                #expect(FileManager.default.fileExists(atPath: socket))
                rig.sync.stop()
                #expect(await until { !FileManager.default.fileExists(atPath: socket) })
            }
        }
    }

    /// The link came back: the next round dials a new master; one dropped meanwhile is redialed.
    @Test func linkBackRenewsTheMaster() async throws {
        let rig = try Rig()
        defer { rig.end() }
        rig.sync.start()
        try write(rig.mac, "a.txt", "a")
        await rig.sync.whole(try rig.boxList())
        let channel = try #require(rig.sync.channel)
        #expect(channel.dials == 1 && channel.up)
        channel.renew()
        #expect(!channel.up)
        try write(rig.mac, "b.txt", "b")
        await rig.sync.whole(try rig.boxList())
        #expect(channel.dials == 2)
        #expect(rig.log().filter { $0 == "connect" }.count == 2)
    }

    /// `-e` reaches rsync as words: a socket path with a space stays one.
    @Test func sshCommandQuotesSpacedWords() {
        let box = SyncBox.via("/usr/bin/ssh", alias: "mybox", base: nil).through(socket: "/Users/me/Library/Application Support/Kore/ssh/m1.sock")
        #expect(box.sshCommand == "/usr/bin/ssh -o ControlMaster=no -o 'ControlPath=/Users/me/Library/Application Support/Kore/ssh/m1.sock' --")
        #expect(box.masterArgv(socket: "/s").suffix(6) == ["ControlPath=/s", "-o", "ControlPersist=no", "--", "mybox", "cat >/dev/null"])
    }

    // MARK: Keeps syncing

    /// From launch, a pair that keeps syncing runs with no window, holding its box's link; a
    /// window shares that sync; turning it off, unpairing or forgetting the box stops it.
    @Test func keepsSyncingWithNoWindow() throws {
        let root = scratch("ksk")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "kore-keep-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = root.appendingPathComponent("cache")
        let list = SyncPairList(defaults: defaults, root: cache)
        let connection = HostConnection(alias: "testbox", cache: HostCache(alias: "testbox", root: cache)) { SyncBatchTests.Offline() }
        list.link = { _ in connection }
        list.makeSync = { pair, connection in
            HostSync(pair: pair, connection: connection, box: SyncBox.via("/usr/bin/false", alias: "testbox", base: nil), root: cache, defaults: defaults)
        }
        let mac = root.appendingPathComponent("Onfinance")
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        list.pair(mac: mac, alias: "testbox", box: "/home/me/Onfinance")
        let path = mac.standardizedFileURL.path
        #expect(list.keptPairs.isEmpty)

        list.startKeeping()
        let kept = try #require(HostSync.live[path])
        #expect(kept.isRunning && connection.inUse && list.keptPairs == [path])

        // A window's sync is the same one; its closing leaves it running.
        let pair = try #require(list.pairs.first)
        let window = list.acquire(pair, connection: connection)
        #expect(window === kept)
        list.relinquish(kept)
        #expect(kept.isRunning)

        // Off: stopped, the link let go. On again: running.
        list.setKeepsSyncing(false, mac: path)
        #expect(!kept.isRunning && !connection.inUse && list.keptPairs.isEmpty)
        list.setKeepsSyncing(true, mac: path)
        let again = try #require(HostSync.live[path])
        #expect(again.isRunning && connection.inUse)

        // Unpaired: stopped.
        list.unpair(alias: "testbox", box: "/home/me/Onfinance")
        #expect(!again.isRunning && !connection.inUse && list.keptPairs.isEmpty)

        // Paired again, then the box forgotten: stopped.
        list.pair(mac: mac, alias: "testbox", box: "/home/me/Onfinance")
        let third = try #require(HostSync.live[path])
        #expect(third.isRunning && connection.inUse)
        HostSync.drop(boxes: ["testbox"], root: cache, defaults: defaults)
        list.reload()
        #expect(!third.isRunning && !connection.inUse && list.keptPairs.isEmpty)
    }

    // MARK: Measured

    /// Bytes on the wire and time per round, each round its own ssh against one held connection,
    /// over real ssh to a user sshd on loopback (scratch keys and config; ~/.ssh untouched). Run
    /// on purpose only: `KORE_SYNC_LOOPBACK=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KORE_SYNC_LOOPBACK"] != nil))
    func measuredOverLoopback() async throws {
        let dir = scratch("ksl")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func run(_ argv: [String]) async { _ = await SyncProcess.run(argv[0], Array(argv.dropFirst())) }
        await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", dir.path + "/hostkey"])
        await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", dir.path + "/userkey"])
        try FileManager.default.copyItem(atPath: dir.path + "/userkey.pub", toPath: dir.path + "/authorized_keys")
        let port = 22000 + Int.random(in: 0..<900)
        try Data("""
            Port \(port)
            ListenAddress 127.0.0.1
            HostKey \(dir.path)/hostkey
            AuthorizedKeysFile \(dir.path)/authorized_keys
            UsePAM no
            StrictModes no
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            PidFile \(dir.path)/pid
            """.utf8).write(to: dir.appendingPathComponent("cfg"))
        let sshd = Process()
        sshd.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        sshd.arguments = ["-D", "-f", dir.path + "/cfg"]
        sshd.standardError = FileHandle.nullDevice
        try sshd.run()
        defer { sshd.terminate() }
        // Every byte either way passes the proxy's tees.
        let proxy = dir.appendingPathComponent("proxy"), ssh = dir.appendingPathComponent("ssh-loop")
        try Data("#!/bin/sh\ntee -a '\(dir.path)/up' | /usr/bin/nc 127.0.0.1 \(port) | tee -a '\(dir.path)/down'\n".utf8).write(to: proxy)
        try Data("""
            #!/bin/sh
            exec /usr/bin/ssh -F /dev/null -i '\(dir.path)/userkey' -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes \\
              -o UserKnownHostsFile='\(dir.path)/known' -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ProxyCommand='\(proxy.path)' "$@"
            """.utf8).write(to: ssh)
        for file in [proxy, ssh] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        func wire() -> Int {
            ["up", "down"].reduce(0) { $0 + (((try? FileManager.default.attributesOfItem(atPath: dir.path + "/" + $1))?[.size] as? Int) ?? 0) }
        }
        _ = await until(5) { FileManager.default.fileExists(atPath: dir.path + "/pid") }
        let rounds = 6
        for held in [false, true] {
            let mac = dir.appendingPathComponent("mac-\(held)"), box = dir.appendingPathComponent("box-\(held)")
            for folder in [mac, box] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            let suite = "kore-sync-measure-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let cache = dir.appendingPathComponent("cache-\(held)")
            let connection = HostConnection(alias: "127.0.0.1", cache: HostCache(alias: "127.0.0.1", root: cache)) { SyncBatchTests.Offline() }
            let sync = try #require(HostSync(pair: SyncPair(mac: mac.path, alias: "127.0.0.1", box: box.path), connection: connection,
                                              box: SyncBox.via(ssh.path, alias: "127.0.0.1", base: nil), root: cache, defaults: defaults))
            sync.heldConnection = held
            sync.start()
            defer { sync.stop() }
            func list() throws -> URL {
                let url = dir.appendingPathComponent("list-\(UUID().uuidString).tsv")
                try Data(SyncTree(root: box).list().map { "\($0.key)\t\($0.value.size)\t\($0.value.mtime)\n" }.joined().utf8).write(to: url)
                return url
            }
            // The first round dials (both ways); the rest are what a sync pays per change.
            try write(mac, "seed.txt", "seed")
            await sync.whole(try list())
            let bytes0 = wire(), start = Date()
            for i in 0..<rounds {
                try write(mac, "f\(i).txt", String(repeating: "x", count: 200))
                await sync.whole(try list())
            }
            let seconds = Date().timeIntervalSince(start)
            #expect(read(box, "f\(rounds - 1).txt")?.count == 200)
            print("sync-measure held=\(held) rounds=\(rounds) bytes/round=\((wire() - bytes0) / rounds) ms/round=\(Int(seconds * 1000) / rounds)")
        }
    }

    // MARK: Rig

    /// A pair whose box is a scratch folder behind a stand-in ssh that acts as a ControlMaster
    /// would: `-M` makes its socket (a file here) and holds it while its command runs; a later
    /// ssh with that `ControlPath` rides it (`mux`), else connects (`connect`).
    @MainActor
    final class Rig {
        let root: URL
        let mac: URL
        let box: URL
        let sync: HostSync
        let defaults: UserDefaults
        private let suite: String
        private let logURL: URL

        init() throws {
            root = scratch("ksc")
            mac = root.appendingPathComponent("mac")
            box = root.appendingPathComponent("box")
            logURL = root.appendingPathComponent("ssh.log")
            for folder in [mac, box] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            let ssh = root.appendingPathComponent("fake-ssh")
            try Data("""
                #!/bin/sh
                master=0; path=
                while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
                  case "$1" in -M) master=1 ;; ControlPath=*) path="${1#ControlPath=}" ;; esac
                  shift
                done
                shift; shift
                if [ $master = 1 ]; then
                  echo connect >> '\(logURL.path)'; : > "$path"; /bin/sh -c "$*"; rm -f "$path"; exit 0
                fi
                if [ -n "$path" ] && [ -e "$path" ]; then echo mux >> '\(logURL.path)'; else echo connect >> '\(logURL.path)'; fi
                exec /bin/sh -c "$*"
                """.utf8).write(to: ssh)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
            suite = "kore-sync-eff-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            let cache = root.appendingPathComponent("cache")
            let connection = HostConnection(alias: "testbox", cache: HostCache(alias: "testbox", root: cache)) { SyncBatchTests.Offline() }
            let pair = SyncPair(mac: mac.path, alias: "testbox", box: box.path)
            sync = HostSync(pair: pair, connection: connection, box: SyncBox.via(ssh.path, alias: "testbox", base: nil), root: cache, defaults: defaults)!
        }

        /// The box folder's list as kore-host would send it.
        func boxList() throws -> URL {
            let url = root.appendingPathComponent("box-\(UUID().uuidString).tsv")
            let lines = SyncTree(root: box).list().map { "\($0.key)\t\($0.value.size)\t\($0.value.mtime)\n" }
            try Data(lines.joined().utf8).write(to: url)
            return url
        }

        func log() -> [String] {
            ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func end() {
            sync.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private func scratch(_ prefix: String) -> URL {
    URL(fileURLWithPath: "/tmp/\(prefix)-\(UUID().uuidString.prefix(6))")
}

private func write(_ root: URL, _ path: String, _ text: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func read(_ root: URL, _ path: String) -> String? {
    (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
}

private func mtime(_ root: URL, _ path: String) -> Int64 {
    let date = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.modificationDate] as? Date) ?? Date()
    return Int64(date.timeIntervalSince1970)
}
