import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// Link 1.12's file verbs on the box (`HostFilesOps`): what the Mac ran as `sh -c` over SSH.
/// A temp folder per test, the verbs called directly.
@Suite("kore-host 1.12 file verbs", .serialized)
@MainActor
struct FileVerbTests {
    private struct Rig {
        let root: String
        let home: String
        let work: String
        let outside: String
        var files: HostFiles { HostFiles(home: home, served: [work]) }

        init() throws {
            root = "/tmp/kfv-\(UUID().uuidString.prefix(8))"
            home = root + "/home"
            work = home + "/work"
            outside = root + "/secret"
            for folder in [work + "/src/deep", outside, home + "/notes"] {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            }
            for (path, text) in [("a.txt", "a\n"), ("src/b.txt", "bb\n"), ("src/deep/c.txt", "ccc\n")] {
                try Data(text.utf8).write(to: URL(fileURLWithPath: work + "/" + path))
            }
            try Data("key\n".utf8).write(to: URL(fileURLWithPath: outside + "/key.txt"))
            try FileManager.default.createSymbolicLink(atPath: work + "/escape", withDestinationPath: outside)
        }

        func there(_ path: String) -> Bool { linkInfo(path) != nil }
        func finish() { try? FileManager.default.removeItem(atPath: root) }
    }

    // MARK: sync.apply

    @Test func applyDeletesFilesAndTheFoldersTheyLeaveEmpty() throws {
        let rig = try Rig()
        defer { rig.finish() }
        let result = rig.files.apply(id: "1", root: rig.work, deletes: ["src/deep/c.txt", "gone.txt"], mkdirs: [])
        #expect(result.ok && result.deleted == 1 && result.skipped == 0)
        #expect(!rig.there(rig.work + "/src/deep"))
        #expect(rig.there(rig.work + "/src/b.txt"))
    }

    @Test func applyLeavesAPathUnderASymlinkedFolder() throws {
        let rig = try Rig()
        defer { rig.finish() }
        let result = rig.files.apply(id: "1", root: rig.work, deletes: ["escape/key.txt"], mkdirs: ["escape/made"])
        #expect(result.ok && result.deleted == 0 && result.made == 0 && result.skipped == 2)
        #expect(rig.there(rig.outside + "/key.txt"))
        #expect(!rig.there(rig.outside + "/made"))
    }

    @Test func applyNeverDeletesAFolder() throws {
        let rig = try Rig()
        defer { rig.finish() }
        let result = rig.files.apply(id: "1", root: rig.work, deletes: ["src", "escape"], mkdirs: [])
        // `escape` is a link: a link to a folder is left too, as the shell's `[ ! -d ]` left it.
        #expect(result.ok && result.deleted == 0 && result.skipped == 2)
        #expect(rig.there(rig.work + "/src/b.txt") && rig.there(rig.work + "/escape"))
    }

    @Test func applyRefusesDotDotAndAbsolutePaths() throws {
        let rig = try Rig()
        defer { rig.finish() }
        for bad in ["../secret/key.txt", "src/../../secret/key.txt", "/etc/passwd", "src//b.txt", "./a.txt", "a\nb"] {
            #expect(rig.files.apply(id: "1", root: rig.work, deletes: [bad], mkdirs: []).code == .invalid, "\(bad)")
            #expect(rig.files.apply(id: "1", root: rig.work, deletes: [], mkdirs: [bad]).code == .invalid, "\(bad)")
        }
        #expect(rig.there(rig.outside + "/key.txt"))
    }

    @Test func applyRefusesARootOutsideTheServedFolders() throws {
        let rig = try Rig()
        defer { rig.finish() }
        #expect(rig.files.apply(id: "1", root: rig.outside, deletes: ["key.txt"], mkdirs: []).code == .deniedPath)
        #expect(rig.files.apply(id: "2", root: rig.home + "/notes", deletes: ["x"], mkdirs: []).code == .deniedPath)
        // Through a link out of the served folder.
        #expect(rig.files.apply(id: "3", root: rig.work + "/escape", deletes: ["key.txt"], mkdirs: []).code == .deniedPath)
        #expect(rig.there(rig.outside + "/key.txt"))
    }

    @Test func applyRefusesPastTheCountCap() throws {
        let rig = try Rig()
        defer { rig.finish() }
        let many = (0...LinkFsOps.applyMax).map { "f\($0)" }
        let result = rig.files.apply(id: "1", root: rig.work, deletes: Array(many.prefix(1000)), mkdirs: Array(many.dropFirst(1000)))
        #expect(result.code == .invalid)
        #expect(rig.files.apply(id: "2", root: rig.work, deletes: Array(many.dropLast()), mkdirs: []).ok)
    }

    @Test func applyMakesFoldersWithTheirParents() throws {
        let rig = try Rig()
        defer { rig.finish() }
        let result = rig.files.apply(id: "1", root: rig.work, deletes: [], mkdirs: ["new/inner", "src"])
        #expect(result.ok && result.made == 2 && result.skipped == 0)
        #expect(HostFiles.look(rig.work + "/new/inner")?.kind == .dir)
    }

    // MARK: fs.stat, fs.find

    @Test func statCountsCarriedFilesAndTheRoomLeft() throws {
        let rig = try Rig()
        defer { rig.finish() }
        try FileManager.default.createDirectory(atPath: rig.work + "/.git", withIntermediateDirectories: true)
        try Data("skipped".utf8).write(to: URL(fileURLWithPath: rig.work + "/.git/HEAD"))
        let result = rig.files.statFolder(id: "1", path: rig.work)
        #expect(result.ok && result.files == 3 && result.size == 9)
        #expect((result.free ?? 0) > 0)
    }

    @Test func statSaysGoneForAMissingFolder() throws {
        let rig = try Rig()
        defer { rig.finish() }
        #expect(rig.files.statFolder(id: "1", path: rig.work + "/nope").code == .goneFile)
        #expect(rig.files.statFolder(id: "2", path: rig.outside).code == .deniedPath)
    }

    @Test func findListsFilesAndLinksWithoutFollowingThem() throws {
        let rig = try Rig()
        defer { rig.finish() }
        let result = rig.files.find(id: "1", path: rig.work)
        #expect(result.ok && result.more == nil)
        #expect(Set(result.paths ?? []) == ["a.txt", "src/b.txt", "src/deep/c.txt", "escape"])
    }

    @Test func findRefusesOutsideTheServedFolders() throws {
        let rig = try Rig()
        defer { rig.finish() }
        #expect(rig.files.find(id: "1", path: rig.outside).code == .deniedPath)
        #expect(rig.files.find(id: "2", path: rig.home + "/notes").code == .deniedPath)
    }

    // MARK: fs.delete {landing}

    @Test func aLandingGoesToTheTrash() throws {
        let rig = try Rig()
        defer { rig.finish() }
        let landing = rig.work + "/.proj.kore-1a2b3c4d"
        try FileManager.default.createDirectory(atPath: landing + "/inner", withIntermediateDirectories: true)
        let trash = rig.home + "/.Trash"
        #expect(rig.files.trashLanding(id: "1", path: landing, trash: .mac(trash)).ok)
        #expect(!rig.there(landing))
        #expect(rig.there(trash + "/.proj.kore-1a2b3c4d/inner"))
    }

    @Test func onlyALandingsNameIsTakenAsOne() throws {
        let rig = try Rig()
        defer { rig.finish() }
        for name in ["src", "a.txt", ".proj.kore-xyz", "proj.kore-1a2b3c4d", ".proj.kore-1a2b3c4"] {
            #expect(rig.files.trashLanding(id: "1", path: rig.work + "/" + name, trash: .mac(rig.home + "/.Trash")).code == .invalid, "\(name)")
        }
        #expect(rig.there(rig.work + "/src") && rig.there(rig.work + "/a.txt"))
    }

    // MARK: Policy

    @Test(arguments: [ControlKind.syncApply, .fsStat, .fsFind, .fsDelete])
    func theVerbsNeedAFullGrant(_ kind: ControlKind) {
        let args = ControlArgs(path: "/srv/w/.a.kore-1a2b3c4d", root: "/srv/w", deletes: ["a"], landing: true)
        #expect(LinkPolicy.checkBox(kind, args, nil, control: .standard) == .deny(.deniedControl, "That needs a grant with full control."))
        #expect(LinkPolicy.checkBox(kind, args, nil, control: .full) == .allow)
    }

    @Test func policyRefusesBadSyncPathsAndTooMany() {
        func check(_ deletes: [String]) -> LinkPolicy.Verdict {
            LinkPolicy.checkBox(.syncApply, ControlArgs(root: "/srv/w", deletes: deletes), nil, control: .full)
        }
        #expect(check(["../x"]) != .allow)
        #expect(check(["/x"]) != .allow)
        #expect(check((0...LinkFsOps.applyMax).map { "f\($0)" }) != .allow)
        #expect(LinkPolicy.checkBox(.syncApply, ControlArgs(root: "w", deletes: ["a"]), nil, control: .full) != .allow)
        #expect(LinkPolicy.checkBox(.fsDelete, ControlArgs(path: "/srv/w/src", landing: true), nil, control: .full) != .allow)
    }

    @Test func theCapIsSaidToFullGrantsOnly() {
        let host = HostDaemon(paths: HostPaths(environment: ["HOME": "/tmp/kfv-none"]))
        #expect(host.welcome(control: .full).caps.contains(LinkFsOps.cap) == true)
        #expect(host.welcome(control: .act).caps.contains(LinkFsOps.cap) == false)
        #expect(host.welcome(control: .watch).caps.contains(LinkFsOps.cap) == false)
    }
}

/// Link 1.12's limits on a watch or act grant (`HostLimits`), on a clock the test turns.
@Suite("kore-host 1.12 rate limits")
struct RateLimitTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let note = LinkMessage.presence(onScreen: true, chatId: nil)
    func cmd(_ id: String, _ command: LinkCommand = .stop(chatId: "c")) -> LinkMessage { .cmd(id: id, command) }

    @Test func aBurstOf40GoesThenMessagesDrop() {
        var limits = HostLimits()
        for _ in 0..<40 { #expect(limits.admit(note, at: start) == .ok) }
        #expect(limits.admit(note, at: start) == .drop)
        // A second later, 20 more.
        #expect(limits.admit(note, at: start + 1) == .ok)
    }

    @Test func aCommandPastTheMessageRateIsAnswered() {
        var limits = HostLimits()
        for _ in 0..<40 { _ = limits.admit(note, at: start) }
        #expect(limits.admit(cmd("x"), at: start) == .refuse("x"))
    }

    @Test func farPastTheRateEndsTheLink() {
        var limits = HostLimits()
        var verdicts: [HostLimits.Verdict] = []
        for _ in 0..<200 { verdicts.append(limits.admit(note, at: start)) }
        #expect(verdicts.contains(.end))
        #expect(verdicts.firstIndex(of: .end) == 40 + 100)
    }

    @Test func uploadChunksArentCounted() {
        var limits = HostLimits()
        for _ in 0..<500 { #expect(limits.admit(.blobPutChunk(uploadId: "u", index: 0, data: ""), at: start) == .ok) }
    }

    @Test func thirtyCommandsAMinute() {
        var limits = HostLimits()
        for i in 0..<30 { #expect(limits.admit(cmd("\(i)"), at: start + Double(i)) == .ok) }
        #expect(limits.admit(cmd("31"), at: start + 30) == .refuse("31"))
        #expect(limits.admit(cmd("32"), at: start + 60) == .ok)
    }

    @Test func tenSendsAMinute() {
        var limits = HostLimits()
        let send = { (i: Int) in LinkMessage.cmd(id: "s\(i)", .send(chatId: "c", text: "hi", blobs: [])) }
        for i in 0..<10 { #expect(limits.admit(send(i), at: start + Double(i)) == .ok) }
        #expect(limits.admit(send(10), at: start + 10) == .refuse("s10"))
        #expect(limits.admit(cmd("other"), at: start + 10) == .ok)
    }

    @Test func tenAccountCommandsAMinute() {
        var limits = HostLimits()
        let account = { (i: Int) in LinkMessage.cmd(id: "a\(i)", .control(.accountRefresh, ControlArgs())) }
        for i in 0..<10 { #expect(limits.admit(account(i), at: start + Double(i)) == .ok) }
        #expect(limits.admit(account(10), at: start + 10) == .refuse("a10"))
    }

    @Test func twoHistoryPagesASecond() {
        var limits = HostLimits()
        let read = LinkMessage.historyList(id: "h", windowId: "w", query: nil, archived: false, offset: 0)
        #expect(limits.admit(read, at: start) == .ok)
        #expect(limits.admit(read, at: start) == .ok)
        #expect(limits.admit(read, at: start) == .refuse("history.list:h"))
        #expect(limits.admit(read, at: start + 1) == .ok)
    }
}

/// The limits on the wire: an act grant past them is told `bye rateLimited`; a full grant isn't
/// limited. The daemon's clock stands still, so nothing refills.
@Suite("kore-host 1.12 rate limits on the link", .serialized)
@MainActor
struct RateLimitLinkTests {
    func flood(_ control: GrantControl) async throws -> (Client, HostRig) {
        let rig = try HostRig()
        let still = Date(timeIntervalSince1970: 1_800_000_000)
        rig.host.now = { still }
        try rig.host.start()
        let grant = try GrantStore(rig.paths.grants).allow("phone", control: control, socket: rig.paths.socket)
        let client = try Client(rig.paths.socket)
        try await until { !client.got.isEmpty }
        client.hello(grant: grant)
        try await until { client.got.count >= 3 }
        for _ in 0..<160 { client.socket.send(.presence(onScreen: true, chatId: nil)) }
        client.socket.send(.cmd(id: "last", .control(.foldersList, ControlArgs())))
        return (client, rig)
    }

    @Test func anActGrantPastTheRateIsToldRateLimited() async throws {
        let (client, rig) = try await flood(.act)
        defer { rig.finish() }
        try await until { client.ended }
        #expect(client.got.last == .bye(.rateLimited))
    }

    @Test func aFullGrantIsntLimited() async throws {
        let (client, rig) = try await flood(.full)
        defer { rig.finish() }
        try await until { client.got.contains { if case .result(let r) = $0 { r.id == "last" } else { false } } }
        #expect(!client.ended)
    }
}

/// Link 1.12's attention on the box and `presence`: Claude and Codex chats alike.
@Suite("kore-host 1.12 attention and presence", .serialized)
@MainActor
struct AttentionTests {
    struct Setup {
        let rig: HostRig
        let backend: FloodStandIn
        let hc: HostChat
        let grant: Grant
    }

    func setup(_ provider: String) async throws -> Setup {
        let rig = try HostRig()
        try rig.host.start()
        let backend = FloodStandIn()
        rig.host.services.backend = { _, _ in backend }
        let grant = try GrantStore(rig.paths.grants).allow("phone", control: .act, socket: rig.paths.socket)
        let hc = try #require(rig.host.newChat(folder: rig.folder.path, provider: provider, modelId: nil))
        await hc.live(services: rig.host.services).start()
        return Setup(rig: rig, backend: backend, hc: hc, grant: grant)
    }

    /// `grant`: another than the setup's, for a second client (a grant's newer link replaces its older).
    func connect(_ s: Setup, grant: Grant? = nil) async throws -> Client {
        let client = try Client(s.rig.paths.socket)
        try await until { !client.got.isEmpty }
        client.hello(grant: grant ?? s.grant)
        try await until { client.got.contains { if case .attnState = $0 { true } else { false } } }
        return client
    }

    /// A command answered: everything the box sent before it has come.
    func roundTrip(_ client: Client, _ id: String) async throws {
        client.socket.send(.cmd(id: id, .control(.foldersList, ControlArgs())))
        try await until { client.got.contains { if case .result(let r) = $0 { r.id == id } else { false } } }
    }

    func events(_ client: Client) -> [(LinkMessage.AttnOp, AttnItem?, AttnTurn?)] {
        client.got.compactMap { if case .attnEvent(_, let op, let item, _, let turn) = $0 { (op, item, turn) } else { nil } }
    }

    let ask = Approval(id: "ap1", title: "Run ls", detail: nil, body: nil, canAlwaysAllow: false, questions: [])

    @Test(arguments: ["claude", "codex"])
    func aWaitingCardRaisesAttention(_ provider: String) async throws {
        let s = try await setup(provider)
        defer { s.rig.finish() }
        let client = try await connect(s)
        s.backend.sink.yield(.approvalRequested(ask))
        try await until { events(client).contains { $0.0 == .open } }
        let item = try #require(events(client).first { $0.0 == .open }?.1)
        #expect(item.chatId == s.hc.id && item.cardId == "ap1" && item.provider == provider)
    }

    @Test(arguments: ["claude", "codex"])
    func aCardGoneClearsIt(_ provider: String) async throws {
        let s = try await setup(provider)
        defer { s.rig.finish() }
        let client = try await connect(s)
        s.backend.sink.yield(.approvalRequested(ask))
        try await until { events(client).contains { $0.0 == .open } }
        s.backend.sink.yield(.approvalWithdrawn("ap1"))
        try await until { events(client).contains { $0.0 == .clear } }
    }

    @Test(arguments: ["claude", "codex"])
    func aTurnEndIsNewsAndAStopIsnt(_ provider: String) async throws {
        let s = try await setup(provider)
        defer { s.rig.finish() }
        let client = try await connect(s)
        s.backend.sink.yield(.turnFinished("t1", .interrupted, duration: nil))
        s.backend.sink.yield(.turnFinished("t2", .completed, duration: nil))
        try await until { events(client).contains { $0.0 == .turn } }
        try await roundTrip(client, "r")
        #expect(events(client).compactMap(\.2).map(\.turnId) == ["t2"])
        #expect(events(client).compactMap(\.2).first?.outcome == .finished)
    }

    @Test func aLaterClientGetsWhatsOpenInItsState() async throws {
        let s = try await setup("codex")
        defer { s.rig.finish() }
        s.backend.sink.yield(.approvalRequested(ask))
        try await until { s.hc.chat?.approvals.pending.isEmpty == false }
        let client = try await connect(s)
        let state = client.got.compactMap { if case .attnState(_, let open, _) = $0 { open } else { nil } }.first
        #expect(state?.map(\.cardId) == ["ap1"])
    }

    @Test func aClosedChatClearsItsAttention() async throws {
        let s = try await setup("claude")
        defer { s.rig.finish() }
        let client = try await connect(s)
        s.backend.sink.yield(.approvalRequested(ask))
        try await until { events(client).contains { $0.0 == .open } }
        s.rig.host.close(s.hc)
        try await until { events(client).contains { $0.0 == .clear } }
    }

    @Test func aBackgroundClientGetsAttentionButNoDeltas() async throws {
        let s = try await setup("claude")
        defer { s.rig.finish() }
        let away = try await connect(s)
        let here = try await connect(s, grant: GrantStore(s.rig.paths.grants).allow("mac", control: .full, socket: s.rig.paths.socket))
        away.socket.send(.presence(onScreen: false, chatId: nil))
        try await roundTrip(away, "p")
        let mark = away.got.count
        s.backend.sink.yield(.approvalRequested(ask))
        try await until { here.got.contains { if case .delta = $0 { true } else { false } } }
        try await until { events(away).contains { $0.0 == .open } }
        try await roundTrip(away, "r")
        #expect(!away.got[mark...].contains { if case .delta = $0 { true } else { false } })
    }

    @Test func aClientBackOnScreenGetsWhatItMissed() async throws {
        let s = try await setup("codex")
        defer { s.rig.finish() }
        let client = try await connect(s)
        client.socket.send(.presence(onScreen: false, chatId: nil))
        try await roundTrip(client, "p")
        s.backend.sink.yield(.approvalRequested(ask))
        try await until { events(client).contains { $0.0 == .open } }
        let mark = client.got.count
        client.socket.send(.presence(onScreen: true, chatId: s.hc.id))
        try await until { client.got[mark...].contains { if case .snapshot = $0 { true } else { false } } }
    }

    @Test func aClientThatNeverSaysIsOnScreen() async throws {
        let s = try await setup("claude")
        defer { s.rig.finish() }
        let client = try await connect(s)
        s.backend.sink.yield(.approvalRequested(ask))
        try await until { client.got.contains { if case .delta = $0 { true } else { false } } }
    }
}
