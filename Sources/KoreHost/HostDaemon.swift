import Foundation
import KoreCore
import LinkProtocol
import src

/// kore-host's daemon: the folders from `config.json`, their chats (restored from disk), and the
/// link over the Unix socket to each connected grant. Idle, it waits on the socket alone: a CLI
/// runs from a send until it has been idle `idleAfter`, and at most `maxRunning` at once.
@MainActor
package final class HostDaemon {
    package let paths: HostPaths
    package let services = HostServices()
    package private(set) var config: HostConfig
    package private(set) var chats: [HostChat] = []
    private var listener: HostListener?
    private var connections: [LinkClient] = []
    private let epoch = UUID().uuidString.lowercased()
    /// A chat's CLI stops after this long with nothing to do; the next send resumes it.
    package var idleAfter: TimeInterval = 600
    package var maxRunning = 3
    private var idleStops: [String: DispatchWorkItem] = [:]
    private var signIns: [String: SignInHandle] = [:]
    /// Whether `gh` is signed in, as last read: on a connect and after `auth.gh`.
    package private(set) var ghSignedIn = false
    private var ghLogin: Process?
    package static let version = "0.1"

    package init(paths: HostPaths) {
        self.paths = paths
        config = HostConfig.load(paths.config)
        services.onEvent = { [weak self] chat, event in self?.noted(chat, event) }
        let note = paths.state.appendingPathComponent("instructions.md")
        try? HostPaths.privateFile(Data(HostServices.instructions(host: ProcessInfo.processInfo.hostName).utf8), to: note)
        services.instructions = note
        let dirs = (try? FileManager.default.contentsOfDirectory(at: paths.chats, includingPropertiesForKeys: nil)) ?? []
        chats = dirs.compactMap(HostChat.load).sorted { $0.record.created < $1.record.created }
        for chat in chats { watch(chat) }
    }

    /// Starts listening; the socket exists when this returns.
    package func start() throws {
        try HostPaths.privateFolder(paths.state)
        listener = try HostListener(path: paths.socket) { [weak self] socket in self?.accepted(socket) }
        try? HostPaths.privateFile(Data("\(getpid())\n".utf8), to: paths.pid)
    }

    package func stop() {
        for connection in connections { connection.end(.quit) }
        for chat in chats { chat.sleep() }
        listener?.stop()
        try? FileManager.default.removeItem(at: paths.pid)
    }

    /// Grants were revoked (`kore-host revoke` signals the daemon): their connections close.
    package func grantsChanged() {
        let store = GrantStore(paths.grants)
        for connection in connections {
            guard let grant = connection.grant else { continue }
            if store.load(grant.name)?.secret != grant.secret { connection.end(.auth) }
        }
    }

    // MARK: Folders and chats

    package var folders: [LinkMessage.Folder] { config.folders.map { .init(windowId: Self.windowID($0), path: $0) } }

    static func windowID(_ folder: String) -> String { StableID.of(folder, prefix: "w_") }

    func folder(windowId: String) -> String? { config.folders.first { Self.windowID($0) == windowId } }

    /// Adds a folder to `config.json`: an absolute path to a folder that exists.
    func addFolder(_ path: String) -> String? {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: standard, isDirectory: &isDir), isDir.boolValue else { return nil }
        if !config.folders.contains(standard) {
            config.folders.append(standard)
            try? config.save(paths.config)
            broadcastWindows()
        }
        return standard
    }

    package func newChat(folder: String, provider: String, modelId: String?) -> HostChat? {
        guard config.folders.contains(folder), Registry.provider(provider) != nil,
            let chat = try? HostChat.create(provider: provider, folder: folder, modelId: modelId, in: paths.chats)
        else { return nil }
        chats.append(chat)
        watch(chat)
        broadcast(windows: true, chats: [chat])
        return chat
    }

    func chat(_ id: String) -> HostChat? { chats.first { $0.id == id } }

    private func watch(_ chat: HostChat) {
        chat.changed = { [weak self] hc, upserts, removed, order, turns, reset in
            self?.transcriptChanged(hc, upserts: upserts, removed: removed, order: order, turns: turns, reset: reset)
        }
    }

    /// The chat's live `Chat`, its CLI let in under the cap: an idle one stops to make room.
    func live(_ hc: HostChat) -> Chat? {
        if let chat = hc.chat { return chat }
        let running = chats.filter(\.cliRunning)
        if running.count >= maxRunning {
            guard let quiet = running.filter(\.idle).min(by: { $0.lastUsed < $1.lastUsed }) else { return nil }
            sleep(quiet)
        }
        return hc.live(services: services)
    }

    private func sleep(_ hc: HostChat) {
        idleStops.removeValue(forKey: hc.id)?.cancel()
        hc.sleep()
        broadcast(chats: [hc])
        // The CLI's pipes and the chat's state go with it: their memory goes back once they have.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { HostMemory.releaseSoon() } }
    }

    /// After an event or a command: a chat with nothing to do stops its CLI after `idleAfter`; one
    /// at work keeps it.
    private func armIdle(_ hc: HostChat) {
        idleStops.removeValue(forKey: hc.id)?.cancel()
        guard hc.cliRunning, hc.idle else { return }
        let stop = DispatchWorkItem { [weak self, weak hc] in
            MainActor.assumeIsolated {
                guard let self, let hc, hc.idle else { return }
                self.sleep(hc)
            }
        }
        idleStops[hc.id] = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + idleAfter, execute: stop)
    }

    private func noted(_ chat: Chat, _ event: ChatEvent) {
        guard let hc = chats.first(where: { $0.chat === chat }) else { return }
        hc.noted(chat)
        armIdle(hc)
        broadcast(chats: [hc])
    }

    // MARK: Connections

    private func accepted(_ socket: HostSocket) {
        let connection = LinkClient(socket: socket, host: self)
        connections.append(connection)
        connection.begin()
    }

    func ended(_ connection: LinkClient) {
        connections.removeAll { $0 === connection }
        HostMemory.releaseSoon()
    }

    /// One connection per grant: a newer one for a grant already connected is turned away.
    func admit(_ connection: LinkClient, grant: Grant) -> Bool {
        !connections.contains { $0 !== connection && $0.grant?.name == grant.name }
    }

    func welcome(control: GrantControl) -> LinkMessage.Welcome {
        ghSignedIn = GitHubLogin.signedIn()
        return LinkMessage.Welcome(
            proto: LinkVersion(major: LinkProto.major, minor: LinkProto.boxMinor), epoch: epoch,
            host: .init(name: ProcessInfo.processInfo.hostName, koreVersion: Self.version, kind: "box", ghSignedIn: ghSignedIn), providers: HostMeta.providers(),
            policy: .init(sendMaxLevel: .danger, control: control == .full ? .full : .standard),
            caps: ["tx", "attn", "commands", "control", "box"])
    }

    var windows: [LinkWindow] {
        config.folders.map { folder in
            let tabs = chats.filter { $0.record.folder == folder }.map { LinkTab(id: "t_" + $0.id, kind: .chat, title: $0.title, chatId: $0.id) }
            return LinkWindow(
                id: Self.windowID(folder), name: URL(fileURLWithPath: folder).lastPathComponent, path: LinkProjection.homeRelative(folder),
                tabs: tabs, activeTabId: tabs.last?.id)
        }
    }

    private func broadcastWindows() { broadcast(windows: true, chats: []) }

    private func broadcast(windows: Bool = false, chats changed: [HostChat]) {
        guard !connections.isEmpty else { return }
        let windows = windows ? self.windows : nil
        guard !changed.isEmpty || windows != nil else { return }
        let lower = changed.map { HostMeta.meta($0) }
        let any = changed.map { HostMeta.meta($0, raise: true) }
        for connection in connections where connection.proven {
            connection.delta(windows: windows, chats: connection.grant?.control == .full ? any : lower)
        }
    }

    private func transcriptChanged(_ hc: HostChat, upserts: [LinkEntry], removed: [String], order: [String]?, turns: [LinkTurn], reset: Bool) {
        for connection in connections where connection.proven && connection.follows(hc.id) {
            if reset {
                connection.send(.txReset(chatId: hc.id))
                connection.page(hc, last: nil)
            } else {
                connection.txDelta(hc, upserts: upserts, removed: removed, order: order, turns: turns)
            }
        }
    }

    // MARK: Commands

    /// What a grant may do: `watch` reads, `act` works in chats and folders, `full` also the accounts.
    /// The command's result; nil when it comes later, through `reply` (an account's call).
    func apply(_ command: LinkCommand, id: String, control: GrantControl, reply: @escaping @MainActor (LinkMessage.Result) -> Void) -> LinkMessage.Result? {
        func fail(_ code: ResultCode, _ message: String) -> LinkMessage.Result { .init(id: id, ok: false, code: code, message: message) }
        guard control != .watch else { return fail(.deniedControl, "This grant only watches.") }
        let hc = command.chatId.flatMap(chat)
        if command.chatId != nil, hc == nil { return fail(.goneChat, "No such chat on this box.") }
        switch command {
        case .send(_, let text, let blobs):
            guard let hc else { return fail(.goneChat, "") }
            guard blobs.isEmpty else { return fail(.invalid, "Uploads aren't on the box yet.") }
            if case .deny(let code, let message) = Self.check(command, HostMeta.facts(hc, raise: control == .full), control: control) { return fail(code, message) }
            guard let chat = live(hc) else { return fail(.busy, "Too many CLIs are running on this box.") }
            guard chat.sendFromLink(text) else { return fail(.busy, "The chat can't take a message right now.") }
            armIdle(hc)
            broadcast(chats: [hc])
            return .init(id: id, ok: true)
        case .stop:
            hc?.chat?.stop()
            return .init(id: id, ok: true)
        case .answer(_, let cardId, let action, _, let answers):
            guard let hc else { return fail(.goneChat, "") }
            if case .deny(let code, let message) = Self.check(command, HostMeta.facts(hc, raise: control == .full), control: control) { return fail(code, message) }
            guard let chat = hc.chat else { return fail(.goneCard, "That was answered or withdrawn.") }
            if cardId == HostMeta.planReadyID { return planReady(chat, action == .implement ? .implement : .stay, id: id) }
            guard let approval = chat.approvals.pending.first(where: { $0.id == cardId }) else { return fail(.goneCard, "That was answered or withdrawn.") }
            let decision: Decision
            switch action {
            case .allow: decision = .allow
            case .deny: decision = .deny
            case .approvePlan: decision = .approvePlan(autoAcceptEdits: false)
            case .approvePlanAcceptEdits where control == .full: decision = .approvePlan(autoAcceptEdits: true)
            case .keepPlanning: decision = .keepPlanning
            case .submitAnswers: decision = .answers(answers ?? [:])
            default: return fail(.action, "That card doesn't take that answer.")
            }
            chat.answer(approval, decision)
            broadcast(chats: [hc])
            return .init(id: id, ok: true)
        case .setMode(_, let modeId):
            guard let hc else { return fail(.goneChat, "") }
            if case .deny(let code, let message) = Self.check(command, HostMeta.facts(hc, raise: control == .full), control: control) { return fail(code, message) }
            hc.live(services: services).setMode(modeId, remember: false)
            if let chat = hc.chat { hc.noted(chat) }
            armIdle(hc)
            broadcast(chats: [hc])
            return .init(id: id, ok: true)
        case .setPlan(_, let on):
            guard let hc else { return fail(.goneChat, "") }
            if case .deny(let code, let message) = Self.check(command, HostMeta.facts(hc, raise: control == .full), control: control) { return fail(code, message) }
            hc.live(services: services).setPlanMode(on)
            armIdle(hc)
            broadcast(chats: [hc])
            return .init(id: id, ok: true)
        case .planReady(_, let choice):
            guard let hc, let chat = hc.chat else { return fail(.goneCard, "No plan is waiting.") }
            if case .deny(let code, let message) = Self.check(command, HostMeta.facts(hc, raise: control == .full), control: control) { return fail(code, message) }
            return planReady(chat, choice, id: id)
        case .new(let windowId, let provider):
            return newChat(id: id, folder: folder(windowId: windowId), provider: provider, modelId: nil)
        case .control(let kind, let args):
            return self.control(kind, args, id: id, control: control, reply: reply)
        case .unknown:
            return fail(.invalid, "The box doesn't know that command.")
        }
    }

    private func newChat(id: String, folder: String?, provider: String, modelId: String?) -> LinkMessage.Result {
        guard let folder else { return .init(id: id, ok: false, code: .goneFolder, message: "That folder isn't on this box.") }
        guard let hc = newChat(folder: folder, provider: provider, modelId: modelId) else {
            return .init(id: id, ok: false, code: .invalid, message: "No such CLI, or the folder isn't served.")
        }
        return .init(id: id, ok: true, chatId: hc.id, windowId: Self.windowID(folder))
    }

    private func planReady(_ chat: Chat, _ choice: LinkCommand.PlanChoice, id: String) -> LinkMessage.Result {
        guard chat.approvals.offerImplementPlan else { return .init(id: id, ok: false, code: .goneCard, message: "No plan is waiting.") }
        switch choice {
        case .implement:
            chat.setPlanMode(false)
            chat.approvals.offerImplementPlan = false
            let ok = chat.sendFromLink("Implement the plan.")
            return .init(id: id, ok: ok, code: ok ? nil : .busy)
        case .stay, .unknown:
            chat.stayInPlanMode()
            return .init(id: id, ok: true)
        }
    }

    private func control(_ kind: ControlKind, _ args: ControlArgs, id: String, control: GrantControl, reply: @escaping @MainActor (LinkMessage.Result) -> Void) -> LinkMessage.Result? {
        func fail(_ code: ResultCode, _ message: String) -> LinkMessage.Result { .init(id: id, ok: false, code: code, message: message) }
        switch kind {
        case .chatNew:
            let folder = args.folder.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? args.windowId.flatMap(self.folder(windowId:))
            return newChat(id: id, folder: folder, provider: args.provider ?? "", modelId: args.modelId)
        case .chatSetModel:
            guard let hc = args.chatId.flatMap(chat), let model = args.modelId, !model.isEmpty else { return fail(.invalid, "Name the chat and the model.") }
            if let chat = hc.chat, let option = chat.controls.models.first(where: { $0.id == model }) {
                chat.setModel(option)
            } else if let chat = hc.chat {
                chat.launchModel = model
            }
            hc.setModel(model)
            broadcast(chats: [hc])
            return .init(id: id, ok: true)
        case .foldersList:
            return .init(id: id, ok: true, folders: folders)
        case .folderAdd:
            guard let path = args.path, addFolder(path) != nil else { return fail(.goneFolder, "An absolute path to a folder on the box.") }
            return .init(id: id, ok: true, folders: folders)
        case .authGh:
            guard control == .full else { return fail(.deniedControl, "GitHub's sign-in needs a grant with full control.") }
            return gitHub(id: id, reply: reply)
        case .accountSignIn, .accountSubmit, .accountCancel, .accountSignOut, .accountRefresh:
            guard control == .full else { return fail(.deniedControl, "Accounts need a grant with full control.") }
            return account(kind, args, id: id, reply: reply)
        default:
            return fail(.invalid, "The box doesn't take that command.")
        }
    }

    // MARK: GitHub

    /// `gh auth login --web` on the box: the result carries the page and code once `gh` prints
    /// them; `<id>:done` says how it ended, and `ghSignedIn` follows in a delta.
    private func gitHub(id: String, reply: @escaping @MainActor (LinkMessage.Result) -> Void) -> LinkMessage.Result? {
        if ghLogin?.isRunning == true { ghLogin?.terminate() }
        ghLogin = GitHubLogin.start(
            started: { found, said in
                Task { @MainActor in
                    if let found {
                        reply(.init(id: id, ok: true, url: found.url, authCode: found.code))
                    } else {
                        let line = said.split(separator: "\n").last.map(String.init) ?? "gh didn't give a code."
                        reply(.init(id: id, ok: false, code: .invalid, message: line))
                    }
                }
            },
            ended: { [weak self] ok in
                Task { @MainActor in
                    guard let self else { return }
                    self.ghLogin = nil
                    self.ghSignedIn = GitHubLogin.signedIn()
                    reply(.init(id: id + ":done", ok: ok, message: ok ? "gh is signed in." : "gh didn't sign in."))
                    for connection in self.connections where connection.proven {
                        connection.send(.delta(rev: connection.nextRev(), windows: nil, chats: nil, removed: nil, extras: LinkExtras(ghSignedIn: self.ghSignedIn)))
                    }
                }
            })
        return nil
    }

    // MARK: Accounts

    /// The link's policy: a full grant is full control (it may raise a chat's mode); watch and act
    /// are standard (lower only).
    static func check(_ command: LinkCommand, _ facts: LinkPolicy.ChatFacts, control: GrantControl) -> LinkPolicy.Verdict {
        LinkPolicy.check(command, facts, control: control == .full ? .full : .standard)
    }

    /// The CLIs' own logins on the box. A sign-in's result carries its page (and code) in
    /// `message`, for the client to open; `<id>:done` says how it ended. The others answer once
    /// the CLI has.
    private func account(_ kind: ControlKind, _ args: ControlArgs, id: String, reply: @escaping @MainActor (LinkMessage.Result) -> Void) -> LinkMessage.Result? {
        guard let provider = args.provider.flatMap(Registry.provider) else { return .init(id: id, ok: false, code: .invalid, message: "No such CLI.") }
        // Each call runs the CLI for a moment: its memory goes back once it has answered.
        let answer = reply
        let reply: @MainActor (LinkMessage.Result) -> Void = { result in
            answer(result)
            HostMemory.releaseSoon()
        }
        let ops = provider.account
        let cli = provider.id
        switch kind {
        case .accountRefresh:
            Task {
                let reading = (try? await ops.calls.status()).map(ops.parse)
                reply(Self.told(id: id, provider: cli, reading: reading))
            }
            return nil
        case .accountSignIn:
            // No browser on the box: Codex's device code, and Claude's page whose code is typed back.
            let method = ops.methods.first { $0.id == (args.method ?? Self.boxMethod[cli]) } ?? ops.methods.first
            guard let method else { return .init(id: id, ok: false, code: .invalid, message: "No sign-in method.") }
            let home = URL(fileURLWithPath: NSHomeDirectory())
            Task { [weak self] in
                do {
                    let handle = try await ops.calls.signIn(method.mechanism, SignInContext(folder: home, open: { _ in }))
                    self?.signIns[cli] = handle
                    let page = [handle.url?.absoluteString, handle.manualURL?.absoluteString, handle.code.map { "code " + $0 }].compactMap { $0 }
                    reply(.init(id: id, ok: true, message: page.joined(separator: " ")))
                    _ = try await handle.wait()
                    self?.signIns[cli] = nil
                    let reading = (try? await ops.calls.status()).map(ops.parse)
                    reply(Self.told(id: id + ":done", provider: cli, reading: reading))
                } catch {
                    self?.signIns[cli] = nil
                    reply(.init(id: id, ok: false, code: .invalid, message: AccountReason.of(error) ?? "Couldn't sign in."))
                }
            }
            return nil
        case .accountSubmit:
            guard let handle = signIns[cli], let submit = handle.submit else { return .init(id: id, ok: false, code: .invalid, message: "No sign-in waits for a code.") }
            let input = args.input ?? ""
            Task {
                let done = (try? await submit(input)) != nil
                reply(.init(id: id, ok: done, code: done ? nil : .invalid))
            }
            return nil
        case .accountCancel:
            if let handle = signIns.removeValue(forKey: cli) { Task { await handle.cancel() } }
            return .init(id: id, ok: true)
        case .accountSignOut:
            Task {
                let done = (try? await ops.calls.signOut()) != nil
                reply(.init(id: id, ok: done, code: done ? nil : .invalid, message: done ? "Signed out." : "Couldn't sign out."))
            }
            return nil
        default:
            return .init(id: id, ok: false, code: .invalid, message: "The box doesn't take that command.")
        }
    }

    /// The sign-in a box uses when the client names none.
    static let boxMethod = ["claude": "claudeai", "codex": "chatgptDeviceCode"]

    private static func told(id: String, provider: String, reading: AccountReading?) -> LinkMessage.Result {
        let message: String =
            switch reading {
            case .signedIn(let identity)?: "Signed in" + (identity.email.map { " as " + $0 } ?? "") + "."
            case .signedOut?: "\(provider) isn't signed in."
            case nil: "Couldn't read \(provider)'s account."
            }
        return .init(id: id, ok: reading != nil, message: message)
    }
}
