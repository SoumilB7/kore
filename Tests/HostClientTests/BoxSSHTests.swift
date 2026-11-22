import Foundation
import Testing

@testable import HostClient

/// 0.3.10, the owner's "sync chats + files broken": every ssh, scp and rsync Kore runs to a box
/// takes the route the tailnet takes now (`BoxSSH`, `SSHTailnetRoute`), as the link does; a
/// stopped one says why in a plain line; a sync paused on an unreachable box goes again by itself.
@Suite("Box SSH: one route for every ssh", .serialized)
@MainActor
struct BoxSSHTests {
    /// mybox's alias names a stopped Tailscale's address; the link runs on Kore's own tailnet.
    nonisolated static let route = [
        "-o", "HostName=100.87.122.76", "-o", "HostKeyAlias=100.91.66.71", "-o", #"ProxyCommand="/K app/kore-tailnet" nc -socket "/S p/kt.sock" %h %p"#,
    ]

    func routed<T>(_ body: () async throws -> T) async rethrows -> T {
        BoxSSH.route = { $0 == "mybox" ? Self.route : [] }
        defer { BoxSSH.route = nil }
        return try await body()
    }

    @Test func theSyncAndEveryCopyGoOnTheRoute() async throws {
        try await routed {
            let box = try #require(SyncBox.ssh("mybox"))
            // ssh, Kore's options, then the route, then `--` and the alias.
            #expect(box.ssh == ["/usr/bin/ssh"] + SyncBox.sshOptions + Self.route)
            #expect(box.shellArgv("true").suffix(3) == ["--", "mybox", "sh -c 'true' sh"])
            #expect(box.shellArgv("true").contains(Self.route[5]))
            #expect(box.masterArgv(socket: "/s").contains(Self.route[5]))
            // rsync's -e: the route's ProxyCommand one quoted word.
            let e = try #require(box.rsyncOptions(false).last)
            #expect(e.contains(#"'ProxyCommand="/K app/kore-tailnet" nc -socket "/S p/kt.sock" %h %p'"#))
            // Through the held connection: still routed, the same channel whatever the route.
            let held = box.through(socket: "/sock")
            #expect(held.ssh.suffix(4) == ["-o", "ControlMaster=no", "-o", "ControlPath=/sock"] && held.ssh.contains(Self.route[1]))
            let key = box.channelKey
            BoxSSH.route = { _ in [] }
            #expect(box.ssh == ["/usr/bin/ssh"] + SyncBox.sshOptions && box.channelKey == key)
        }
    }

    @Test func theAttachSetUpAndKeyScanGoOnTheRouteToo() async {
        await routed {
            let attach = SSHTransport.arguments(alias: "mybox", grant: "mac")
            #expect(attach.starts(with: ["-T"]) && attach.contains(Self.route[5]) && attach.suffix(5) == ["mybox", SSHTransport.defaultCommand, "attach", "--as", "mac"])
            let ran = await BoxSSH.argv("mybox", program: "/bin/ssh", options: ["-T"], ["sh -s"])
            #expect(ran == ["/bin/ssh", "-T"] + Self.route + ["--", "mybox", "sh -s"])
            // A typed destination: its user and port before the route, its host after `--`.
            #expect(await BoxSSH.argv("me@box.lan:2222", options: [], ["x"]).suffix(3) == ["--", "box.lan", "x"])
        }
    }

    /// openrsync (macOS's /usr/bin/rsync) hands ssh the route's ProxyCommand as one word.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/rsync")))
    func rsyncKeepsTheProxyCommandWhole() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kbs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let said = dir.appendingPathComponent("argv"), fake = dir.appendingPathComponent("fake ssh")
        try "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done > '\(said.path)'\nexit 255\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        try await routed {
            let box = try #require(SyncBox.ssh("mybox", program: fake.path))
            _ = await SyncProcess.run("/usr/bin/rsync", ["-a"] + box.rsyncOptions(false) + [box.spec("/x/"), dir.appendingPathComponent("to").path + "/"])
            let words = try String(contentsOf: said, encoding: .utf8).split(separator: "\n").map(String.init)
            #expect(words.contains(Self.route[5]), "\(words)")
            #expect(words.contains("HostName=100.87.122.76"))
        }
    }

    @Test func aStoppedCopySaysWhyPlainly() {
        let rows: [(Int32, String, BoxCopyWords.Why)] = [
            (12, "ssh: connect to host 100.91.66.71 port 22: Operation timed out\nrsync(1234): error: unexpected end of file", .unreachable),
            (255, "ssh: Could not resolve hostname mybox: nodename nor servname provided", .unreachable),
            (255, "ssh: connect to host 10.0.0.2 port 22: Connection refused", .unreachable),
            (255, "me@mybox: Permission denied (publickey).", .keyRefused),
            (255, "Host key verification failed.", .hostKey),
            (127, "sh: rsync: command not found", .noRsync),
            (12, "bash: line 1: rsync: command not found", .noRsync),
            (30, "rsync error: timeout in data send/receive (code 30)", .stalled),
            (11, "rsync: write failed on \"/x\": No space left on device (28)", .full),
            (23, "rsync: open \"/x\" failed: Permission denied (13)", .permission),
            (2, "rsync: protocol version mismatch", .other(2)),
        ]
        for (status, said, why) in rows { #expect(BoxCopyWords.why(status: status, said: said) == why, "\(status) \(said)") }
        #expect(BoxCopyWords.line(status: 12, said: rows[0].1, box: "mybox") == "mybox can't be reached over SSH right now")
        #expect(BoxCopyWords.line(.noRsync, box: "mybox") == "rsync isn't installed on mybox")
        #expect(BoxCopyWords.waitsForRoute(.unreachable) && BoxCopyWords.waitsForRoute(.stalled) && !BoxCopyWords.waitsForRoute(.hostKey))
    }

    /// No ssh or rsync to a box is built outside `BoxSSH`: the route can't drift again.
    @Test func everySSHToABoxGoesThroughBoxSSH() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let walk = try #require(FileManager.default.enumerator(atPath: sources.path))
        var found: [String: String] = [:]
        while let path = walk.nextObject() as? String {
            guard path.hasSuffix(".swift"), !path.hasPrefix("KoreStorylines/"), !path.hasPrefix("korenet-rig/"), !path.hasPrefix("korenet-e2e/") else { continue }
            found[path] = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
        }
        #expect(found.count > 100)
        // The route is read only by BoxSSH (and its own file).
        let routeReaders = found.filter { $0.value.contains("SSHTailnetRoute.options(") }.keys.sorted()
        #expect(routeReaders == ["HostClient/BoxSSH.swift"], "\(routeReaders)")
        // An alias's options are put in an ssh line only by BoxSSH; elsewhere only for `ssh -G`.
        for (path, text) in found where path != "HostClient/BoxSSH.swift" {
            for line in text.split(separator: "\n") where line.contains("address?.options") || line.contains("address.options") {
                #expect(line.contains("\"-G\"") || line.contains("hostName") || path == "HostClient/SSHTailnetRoute.swift", "\(path): \(line)")
            }
        }
        // Every rsync to a box takes its -e from SyncBox (BoxSSH's words).
        for (path, text) in found where text.contains("\"/usr/bin/rsync\"") {
            #expect(text.contains("rsyncOptions(") || text.contains("runRsync"), "\(path) runs rsync without SyncBox's -e")
        }
        // Only HostSync makes a SyncBox.
        let makers = found.filter { $0.value.contains("SyncBox(alias:") }.keys.sorted()
        #expect(makers == ["HostClient/HostSync.swift"], "\(makers)")
    }
}
