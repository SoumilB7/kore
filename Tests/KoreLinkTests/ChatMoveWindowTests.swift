import Foundation
import HostClient
import KoreCore
import KoreHost
import LinkProtocol
import Testing

@testable import KoreUI
@testable import src

/// Link 1.10 through the windows, on HostClient's engine against a kore-host in this process: a
/// box window's chat brought here lands in the pair's Mac folder's window, the box tab turns
/// replica, and Send back puts it in the box window again, live. The session files go by rsync
/// through a stand-in ssh; every CLI folder is a scratch one (never the real `~/.claude`).
@MainActor
@Suite("chat moves through the windows", .serialized)
struct ChatMoveWindowTests {
    static let session = "7d1e3c40-0000-4000-8000-00000000beef"

    func until(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func rows(_ folder: String, count: Int) -> String {
        (0..<count).map { i in
            #"{"type":"user","message":{"role":"user","content":"step \#(i)"},"uuid":"u\#(i)","cwd":"\#(folder)","sessionId":"\#(Self.session)"}"# + "\n"
        }.joined()
    }

    @Test func aBoxChatComesHereAndGoesBackThroughItsWindows() async throws {
        let root = URL(fileURLWithPath: "/tmp/kmw-\(UUID().uuidString.prefix(6))")
        let folder = root.appendingPathComponent("work")
        let mac = root.appendingPathComponent("mac")
        for made in [folder, mac] { try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }

        // The box: a kore-host with one chat whose session file is on its scratch CLI folder.
        let paths = HostPaths(environment: [
            "HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "XDG_RUNTIME_DIR": root.appendingPathComponent("run").path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
        ])
        try HostConfig(folders: [folder.path]).save(paths.config)
        let host = HostDaemon(paths: paths)
        try host.start()
        defer { host.stop() }
        host.sessionEnv = ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("boxclaude").path, "HOME": root.path]
        let grant = try GrantStore(paths.grants).allow("laptop", control: .full, socket: paths.socket)
        let hc = try #require(host.newChat(folder: folder.path, provider: "claude", modelId: "haiku", title: "Repos", session: Self.session))
        let boxFile = root.appendingPathComponent("boxclaude/projects").appendingPathComponent(ClaudeHistory.projectKey(for: folder))
            .appendingPathComponent("\(Self.session).jsonl")
        try FileManager.default.createDirectory(at: boxFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(rows(SessionFiles.real(folder.path), count: 20).utf8).write(to: boxFile)

        // This Mac: the link, the engine on a stand-in ssh, a scratch store and CLI folder.
        let socket = paths.socket.path
        let connection = HostConnection(alias: "local", cache: HostCache(alias: "local", root: root.appendingPathComponent("cache"))) {
            MoveDaemonTransport(path: socket, grant: grant)
        }
        HostConnection.adopt(connection)
        connection.retain()
        defer { connection.release() }
        #expect(await until { connection.isOnline })
        let store = MovedChats(root: root.appendingPathComponent("hosts"))
        ChatPlaces.shared.use(store)
        let mirrors = ChatMirrors.shared.store
        ChatMirrors.shared.store = store
        let ssh = try moveSSH(root)
        let macEnv = ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("macclaude").path, "HOME": root.path]
        let pair = SyncPair(mac: mac.path, alias: "local", box: folder.path)
        var openedLocal: [URL] = []
        var openedBox: [(BoxPlace, String?)] = []
        ChatMoving.engine = { connection in
            var moves = ChatMoves(connection: connection, box: ssh, staging: root.appendingPathComponent("staging"), name: "MacBook", store: store)
            moves.env = macEnv
            return moves
        }
        ChatMoving.pairs = { _, _ in pair }
        ChatMoving.makeSync = { _, _ in nil }
        ChatMoving.openLocal = { openedLocal.append($0) }
        ChatMoving.openBox = { openedBox.append(($0, $1)) }
        defer {
            ChatMoving.engine = { connection in SyncBox.ssh(connection.alias).map { ChatMoves(connection: connection, box: $0) } }
            ChatMoving.pairs = { alias, box in SyncPairList.shared.pair(alias: alias, box: box) ?? SyncPairList.shared.around(alias: alias, box: box) }
            ChatMoving.makeSync = { HostSync(pair: $0, connection: $1) }
            ChatMoving.openLocal = { AppModel.shared?.openFolder($0) }
            ChatMoving.openBox = { AppModel.shared?.openBox($0, chat: $1) }
            ChatMirrors.shared.store = mirrors
            ChatPlaces.shared.use(.shared)
        }

        // The box window, its chat's tab.
        let box = BoxBinding(alias: "local", folder: folder.path)
        let boxWindow = Workspace(folder: box.folderURL, restore: false, box: box)
        box.workspace = boxWindow
        let boxTab = ChatTab()
        boxTab.chat = Chat(
            provider: .claude, folder: box.folderURL, modeMemory: ModeMemory(defaults: nil), compactMemory: AutoCompactMemory(defaults: nil),
            services: BoxChatServices(binding: box, chatId: hc.id))
        boxWindow.tabs = [boxTab]
        #expect(TabMenu.items(boxTab, in: boxWindow) {}.map(\.title).contains("Bring to this Mac"))

        // Bring to this Mac: the sheet (its sync a stand-in, settled), then the button.
        ChatMoving.bring(boxTab, in: boxWindow)
        let sheet = try #require(boxWindow.moveSheet)
        #expect(sheet.folder == SyncPairs.shown(mac: mac.path) && sheet.line == nil)
        sheet.checks?.cancel()
        sheet.sync = .settled
        #expect(sheet.ready)
        sheet.onGo()
        #expect(await until { boxWindow.moveSheet == nil })
        #expect(sheet.line == nil)
        #expect(hc.isReplica)

        // Its folder's window opens and takes it as a local chat, marked from the box.
        let canonical = AppModel.canonical(mac)
        #expect(openedLocal == [canonical])
        let local = Workspace.forWindow(canonical, restore: false)
        let localTab = try #require(local.tabs.first { $0.chat?.status.sessionId == Self.session })
        let model = Workspace.usable("haiku", among: ArsenalModels.seen["claude"] ?? []) ? "haiku" : nil
        #expect(local.activeTab === localTab && localTab.chat?.launchModel == model)
        #expect(ChatPlaces.shared.moved(localTab.chat!)?.alias == "local")
        #expect(TabMenu.items(localTab, in: local) {}.map(\.title).contains("Send back to local"))
        let macFile = root.appendingPathComponent("macclaude/projects").appendingPathComponent(ClaudeHistory.projectKey(for: mac))
            .appendingPathComponent("\(Self.session).jsonl")
        #expect(try String(contentsOf: macFile, encoding: .utf8) == rows(SessionFiles.real(mac.path), count: 20))
        // The box tab: a replica, read-only, with Send back.
        #expect(ChatPlaces.shared.replica(boxTab.chat!) == ChatPlaces.Replica(here: true, name: "this Mac"))
        #expect(ChatView.sendBack(boxTab.chat!, in: boxWindow) != nil)
        #expect(!TabMenu.items(boxTab, in: boxWindow) {}.map(\.title).contains("Bring to this Mac"))

        // Send back from the local tab: it closes, the box window comes forward with the chat.
        let moved = try #require(store.session(Self.session))
        ChatMoving.sendBack(moved, from: local)
        let back = try #require(local.moveSheet)
        #expect(await until { back.chat == nil || back.sync != .checking || back.line != nil })
        back.checks?.cancel()
        back.sync = .settled
        #expect(back.ready)
        back.onGo()
        #expect(await until { local.moveSheet == nil })
        #expect(back.line == nil)
        #expect(!local.tabs.contains { $0.chat?.status.sessionId == Self.session })
        #expect(hc.ownedHere && hc.gen == 2 && store.session(Self.session) == nil)
        #expect(openedBox.count == 1 && openedBox.first?.1 == hc.id && openedBox.first?.0 == BoxPlace(alias: "local", folder: folder.path))
        #expect(ChatPlaces.shared.replica(boxTab.chat!) == nil && boxWindow.activeTab === boxTab)
        #expect(ChatPlaces.shared.gen("local", hc.id) == 2)
    }
}

/// "The box" on this Mac through a stand-in ssh: everything after `--` and the alias runs under `sh -c`.
@MainActor
private func moveSSH(_ root: URL) throws -> SyncBox {
    let ssh = root.appendingPathComponent("fake-ssh")
    try Data("""
        #!/bin/sh
        while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
        shift; shift
        exec /bin/sh -c "$*"
        """.utf8).write(to: ssh)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
    return SyncBox.via(ssh.path, alias: "local", base: root.path)
}

/// The client's end of a socket to an in-process kore-host, the hello's proof filled in as
/// `kore-host attach` fills it.
final class MoveDaemonTransport: HostTransport, @unchecked Sendable {
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let path: String
    private let grant: Grant
    private var socket: HostSocket?
    private var nonce: String?
    private var helloSent = false

    init(path: String, grant: Grant) {
        self.path = path
        self.grant = grant
        (events, continuation) = AsyncStream.makeStream()
    }

    func start() throws {
        try MainActor.assumeIsolated {
            let socket = try HostListener.connect(to: path)
            self.socket = socket
            socket.start(
                max: LinkFrame.outboundMax,
                frame: { [weak self] data in
                    if case .challenge(let n)? = try? LinkMessage.decode(data) { self?.nonce = n }
                    self?.continuation.yield(.frame(data))
                },
                ended: { [weak self] in
                    self?.continuation.yield(.closed("gone"))
                    self?.continuation.finish()
                })
        }
    }

    func send(_ payload: Data) {
        MainActor.assumeIsolated {
            guard !helloSent, case .hello(let proto, let client, _, let commands, _)? = try? LinkMessage.decode(payload) else {
                socket?.send(payload)
                return
            }
            helloSent = true
            let proof = LinkProof.proof(secret: Data(base64Encoded: grant.secret) ?? Data(), nonce: nonce ?? "")
            socket?.send(.hello(proto: proto, client: client, proof: proof, commands: commands, grant: grant.name))
        }
    }

    func close() {
        MainActor.assumeIsolated {
            socket?.close()
            continuation.yield(.closed(nil))
            continuation.finish()
        }
    }
}
