import AppKit
import Foundation
import HostClient
import KoreUI
import LinkProtocol
import src

// Box windows' controls, each driven once (`--tag drive`): the box explorer and its Search here;
// the link-down card, Sync's options, a move's sheet and a synced Mac folder's cue in
// DriveBoxWindowStorylines; the Welcome's folder browser and the agents card's logins in
// DriveBoxWelcomeStorylines. Each talks to a scripted box over pipes (`ScriptedDriveBox`) that
// notes what it was asked, and checks what the window shows.

// MARK: - The box explorer

/// A file's click opens it in a tab (read from the box) and chooses its row; a folder's click
/// lists it on the box and shows its files; the folder's name in the header, and a click under
/// the rows, clear the choice.
final class DriveBoxTreeClicks: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        let spec = DriveBoxSpec(
            alias: "drive-tree", folder: "/home/me/site",
            files: ["/home/me/site/notes.txt": "first\n", "/home/me/site/src/app.swift": "let a = 1\n"])
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        let chosen: @MainActor @Sendable (StoryContext) -> String? = { (try? box($0).workspace())?.storyBoxTreeSelection }
        let asked: @MainActor @Sendable (StoryContext) -> String? = { box($0).asked.joined(separator: " | ") }
        return [
            BoxStep("Open the box folder's window, linked") { try await box($0).open($0) },
            WaitForElement(.id(StoryID.Explorer.row("notes.txt"))),
            Click(.id(StoryID.Explorer.row("notes.txt"))),
            Expect("the file opens in a tab, read from the box", found: asked) { story in
                try box(story).workspace().storyBoxActivePath == spec.folder + "/notes.txt"
                    && box(story).asked.contains("fs.read " + spec.folder + "/notes.txt")
            },
            Expect("its row chosen", found: chosen) { chosen($0) == "notes.txt" },
            Click(.id(StoryID.Explorer.row("src"))),
            Expect("the folder opens: listed on the box, its file shown", found: asked) { story in
                try box(story).asked.contains("fs.list " + spec.folder + "/src") && box(story).workspace().storyBoxTreeRows.contains("src/app.swift")
            },
            Click(.id(StoryID.Explorer.title)),
            Expect("the folder's name clears the choice", found: chosen) { chosen($0) == nil },
            Click(.id(StoryID.Explorer.row("notes.txt"))),
            Expect("the file's row chosen again", found: chosen) { chosen($0) == "notes.txt" },
            Click(.id(StoryID.Explorer.boxBelow)),
            Expect("a click under the rows clears it", found: chosen) { chosen($0) == nil },
        ]
    }
}

/// The tree's keys: ↓ moves the choice, Return renames (the name field: ⌘A, a new name, Return,
/// renamed on the box), ⌘⌫ moves the chosen row to the box's trash after one question.
final class DriveBoxTreeKeys: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        let folder = "/home/me/notes"
        let spec = DriveBoxSpec(
            alias: "drive-keys", folder: folder,
            files: [folder + "/a.txt": "a\n", folder + "/b.txt": "b\n", folder + "/c.txt": "c\n"])
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        let chosen: @MainActor @Sendable (StoryContext) -> String? = { (try? box($0).workspace())?.storyBoxTreeSelection }
        let rows: @MainActor @Sendable (StoryContext) -> [String] = { (try? box($0).workspace())?.storyBoxTreeRows ?? [] }
        let asked: @MainActor @Sendable (StoryContext) -> String? = { box($0).asked.joined(separator: " | ") }
        return [
            BoxStep("Open the box folder's window, linked") { try await box($0).open($0) },
            Do("Kore's questions answered yes") { story in _ = story.stash(DriveConfirms.self) { DriveConfirms() } },
            WaitForElement(.id(StoryID.Explorer.row("c.txt"))),
            Click(.id(StoryID.Explorer.row("a.txt"))),
            Key(.down),
            Expect("↓ chose the next row", found: chosen) { chosen($0) == "b.txt" },
            Key(.returnKey),
            WaitForFocus(.id(StoryID.Explorer.namefield)),
            Key(.cmd("a")),
            TypeText("beta.txt\n"),
            Expect("Return renamed it on the box", found: asked) { story in
                box(story).asked.contains("fs.rename \(folder)/b.txt → \(folder)/beta.txt") && rows(story).contains("beta.txt")
            },
            WaitForElement(.id(StoryID.Explorer.row("beta.txt"))),
            Click(.id(StoryID.Explorer.row("beta.txt"))),
            Key(KeyChord(.backspace, .command)),
            Expect("⌘⌫ asked once and trashed it on the box", found: asked) { story in
                story.stash(DriveConfirms.self) { DriveConfirms() }.asked == ["trash"]
                    && box(story).asked.contains("fs.delete \(folder)/beta.txt") && !rows(story).contains("beta.txt")
            },
        ]
    }
}

/// An empty box folder's New File: the name field, a name, Return: made on the box and opened.
final class DriveBoxEmptyNewFile: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        let folder = "/home/me/empty"
        let spec = DriveBoxSpec(alias: "drive-newfile", folder: folder, dirs: [folder])
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        let asked: @MainActor @Sendable (StoryContext) -> String? = { box($0).asked.joined(separator: " | ") }
        return [
            BoxStep("Open the empty box folder's window, linked") { try await box($0).open($0) },
            WaitForElement(.id(StoryID.Explorer.boxEmptyNewFile)),
            Press(.id(StoryID.Explorer.boxEmptyNewFile)),
            WaitForFocus(.id(StoryID.Explorer.namefield)),
            TypeText("hello.txt\n"),
            Expect("made on the box and open in a tab", found: asked) { story in
                try box(story).asked.contains("fs.create \(folder)/hello.txt") && box(story).workspace().storyBoxActivePath == folder + "/hello.txt"
            },
        ]
    }
}

/// An empty box folder's New Folder: the name field, a name, Return: made on the box, its row in
/// the tree.
final class DriveBoxEmptyNewFolder: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        let folder = "/home/me/blank"
        let spec = DriveBoxSpec(alias: "drive-newfolder", folder: folder, dirs: [folder])
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        let asked: @MainActor @Sendable (StoryContext) -> String? = { box($0).asked.joined(separator: " | ") }
        return [
            BoxStep("Open the empty box folder's window, linked") { try await box($0).open($0) },
            WaitForElement(.id(StoryID.Explorer.boxEmptyNewFolder)),
            Press(.id(StoryID.Explorer.boxEmptyNewFolder)),
            WaitForFocus(.id(StoryID.Explorer.namefield)),
            TypeText("docs\n"),
            Expect("made on the box", found: asked) { box($0).asked.contains("fs.create folder \(folder)/docs") },
            ExpectElement(.id(StoryID.Explorer.row("docs"))),
        ]
    }
}

// MARK: - The box's Search

/// Search: its field takes a query, the box is asked for it, and a hit's line opens its file.
final class DriveBoxSearch: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        let folder = "/home/me/lib"
        let spec = DriveBoxSpec(
            alias: "drive-search", folder: folder,
            files: [folder + "/readme.md": "intro\nfind the needle here\n", folder + "/src/main.c": "int needle = 1;\n"])
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        let asked: @MainActor @Sendable (StoryContext) -> String? = { box($0).asked.joined(separator: " | ") }
        return [
            BoxStep("Open the box folder's window, linked") { try await box($0).open($0) },
            Press(.id(StoryID.Explorer.searchTab)),
            WaitForFocus(.id(StoryID.Explorer.boxSearchField)),
            TypeText("needle"),
            Expect("the box searched the folder for it", found: asked) { box($0).asked.contains("fs.search \(folder) needle") },
            WaitForElement(.id(StoryID.Explorer.boxHit("src/main.c", line: 1))),
            Press(.id(StoryID.Explorer.boxHit("src/main.c", line: 1))),
            Expect("the hit's file opens in a tab", found: asked) { story in
                try box(story).workspace().storyBoxActivePath == folder + "/src/main.c" && box(story).asked.contains("fs.read \(folder)/src/main.c")
            },
        ]
    }
}

/// Find in Folder… on a folder's row scopes Search to it; the scope's × searches the whole folder
/// again.
final class DriveBoxSearchScope: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        let folder = "/home/me/lib"
        let spec = DriveBoxSpec(
            alias: "drive-scope", folder: folder,
            files: [folder + "/readme.md": "the needle\n", folder + "/src/main.c": "int needle = 1;\n"])
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        let asked: @MainActor @Sendable (StoryContext) -> String? = { box($0).asked.joined(separator: " | ") }
        let within: @MainActor @Sendable (StoryContext) -> String? = { (try? box($0).workspace())?.storyBoxSearchWithin }
        return [
            BoxStep("Open the box folder's window, linked") { try await box($0).open($0) },
            WaitForElement(.id(StoryID.Explorer.row("src"))),
            RightClick(.id(StoryID.Explorer.row("src"))),
            WaitForElement(.id(StoryID.Options.panel)),
            BoxTailnetStory.PressRow(title: "Find in Folder…"),
            Expect("Search is scoped to src", found: within) { within($0) == folder + "/src" },
            WaitForFocus(.id(StoryID.Explorer.boxSearchField)),
            TypeText("needle"),
            Expect("the box searched src", found: asked) { box($0).asked.contains("fs.search \(folder)/src needle") },
            Press(.id(StoryID.Explorer.boxSearchScope)),
            Expect("the scope's × searches the whole folder again", found: asked) { story in
                within(story) == nil && box(story).asked.contains("fs.search \(folder) needle")
            },
        ]
    }
}

// MARK: - The scripted box

/// What a drive box holds: its name, the folder its window shows, folders and files (absolute;
/// their parents are folders too), welcome caps beyond the usual, and the chats open in the folder.
struct DriveBoxSpec: Sendable {
    var alias: String
    var folder: String
    var dirs: [String] = []
    var files: [String: String] = [:]
    var caps: [String] = []
    var chats: [DriveBoxChat] = []
}

struct DriveBoxChat: Sendable {
    var id: String
    var title: String
}

/// The storyline's drive box, made on first use.
@MainActor func driveBox(_ story: StoryContext, _ spec: DriveBoxSpec) -> ScriptedDriveBox {
    story.stash(ScriptedDriveBox.self) { ScriptedDriveBox(story, spec) }
}

/// A box for one storyline, over pipes: each dial's hello gets a welcome and a snapshot (one
/// window per folder it serves, the spec's chats in the first); `fs.*` is answered from the
/// folders and files it holds (list, read, create, rename, delete, mkdir, search, watch);
/// `folders.list` and `folder.add` from what it serves; a login's refresh, sign-in, pasted code
/// and cancel as a box's CLI answers them. While `down`, a dial gets a link that ends at once.
@MainActor
final class ScriptedDriveBox: StoryFinishing {
    static let home = "/home/me"
    static let owner = "owner@example.com"
    static let page = "https://claude.ai/oauth/authorize?box=drive"
    /// A device sign-in's page and its code (any CLI but Claude here).
    static let devicePage = "https://example.com/device"
    static let deviceCode = "DRVE-4242"

    let alias: String
    let folder: String
    let connection: HostConnection
    /// What it was asked, in order: "fs.list <path>" ("~" for its home), "fs.read <path>",
    /// "fs.create [folder ]<path>", "fs.rename <from> → <to>", "fs.delete <path>", "fs.mkdir <path>",
    /// "fs.search <root> <query>", "folder.add <path>", "account.<kind> <provider or code>"…
    private(set) var asked: [String] = []
    private(set) var dials = 0
    /// A count a storyline keeps (the dials before a press).
    var mark = 0
    /// Dials meet a box that isn't there.
    var down = false
    /// The window keys and typing go to (the Welcome); else its box window.
    weak var front: NSWindow?
    private var dirs: Set<String>
    private var files: [String: String]
    private var served: [String]
    private let caps: [String]
    private let chats: [DriveBoxChat]
    private var signedIn: Set<String> = []
    /// Each CLI's sign-in waiting for its end, by its command's id.
    private var signIns: [String: String] = [:]
    /// `fs.stat` answers wait until `releaseStat` (a pairing seen while it checks).
    var holdStat = false
    private var heldStats: [@MainActor () -> Void] = []
    private var rev = 1
    private var transport: PipeTransport?
    private var pump: Task<Void, Never>?

    init(_ story: StoryContext, _ spec: DriveBoxSpec) {
        alias = spec.alias
        folder = spec.folder
        var dirs = Set(spec.dirs + [spec.folder, Self.home, "/"])
        for path in spec.dirs + Array(spec.files.keys) + [spec.folder] {
            var parent = (path as NSString).deletingLastPathComponent
            while parent.count > 1 {
                dirs.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        self.dirs = dirs
        files = spec.files
        served = [spec.folder]
        caps = spec.caps
        chats = spec.chats
        let cache = HostCache(alias: spec.alias, root: story.outputs.appendingPathComponent("box-\(story.name)", isDirectory: true))
        weak var box: ScriptedDriveBox?
        connection = HostConnection(alias: spec.alias, cache: cache) { box?.dial() ?? PipeTransport(input: .nullDevice, output: .nullDevice) }
        box = self
        HostConnection.adopt(connection)
    }

    /// The storyline's keys and typing go to this box's windows (or `front`).
    func drive(_ story: StoryContext) {
        _ = story.stash(InputDriver.self) { InputDriver(window: { [weak self] in self?.inputWindow }, real: nil) }
    }

    var inputWindow: NSWindow? { front ?? (try? workspace())?.window }

    /// Opens its folder's window as the Welcome's row does, and waits for the link.
    func open(_ story: StoryContext) async throws {
        drive(story)
        guard let model = AppModel.shared else { throw StoryFailure.other("the app model isn't up") }
        model.storyOpenBox(alias: alias, folder: folder)
        let window = try await story.wait("the box window, linked") { () -> NSWindow? in
            guard let workspace = try? self.workspace(), self.connection.isOnline else { return nil }
            return workspace.window
        }
        window.setContentSize(story.windowSize)
        try await story.idle()
    }

    /// Its latest open window.
    func workspace() throws -> Workspace {
        guard let workspace = Workspace.all.allObjects.last(where: { !$0.isClosed && $0.boxAlias == alias }) else {
            throw StoryFailure.modelMissing("\(alias)'s box window")
        }
        return workspace
    }

    /// Its window's tab for a chat, by its title.
    func tab(_ title: String) throws -> ChatTab {
        guard let tab = try workspace().tabs.first(where: { $0.chat?.title == title }) else {
            throw StoryFailure.modelMissing("the “\(title)” tab in \(alias)'s window")
        }
        return tab
    }

    // MARK: The link

    private func dial() -> any HostTransport {
        dials += 1
        if down {
            // A link that ends as it starts (reading /dev/null never says so).
            let ended = Pipe()
            try? ended.fileHandleForWriting.close()
            return PipeTransport(input: ended.fileHandleForReading, output: .nullDevice)
        }
        let toHost = Pipe(), toMac = Pipe()
        let mac = PipeTransport(input: toMac.fileHandleForReading, output: toHost.fileHandleForWriting)
        let end = PipeTransport(input: toHost.fileHandleForReading, output: toMac.fileHandleForWriting)
        try? end.start()
        pump?.cancel()
        transport = end
        pump = Task { [weak self] in
            for await event in end.events {
                guard case .frame(let data) = event, let self, self.transport === end else { continue }
                self.arrived(data)
            }
        }
        end.send((try? LinkMessage.challenge(nonce: "bm9uY2U=").encoded()) ?? Data())
        return mac
    }

    private func send(_ message: LinkMessage) { transport?.send((try? message.encoded()) ?? Data()) }

    private func send(_ result: FilesResult) { transport?.send((try? JSONEncoder().encode(result)) ?? Data()) }

    private func result(_ id: String, ok: Bool = true, _ fields: [String: Any] = [:]) {
        var json = fields
        json["t"] = "result"
        json["id"] = id
        json["ok"] = ok
        transport?.send((try? JSONSerialization.data(withJSONObject: json)) ?? Data())
    }

    private func welcome() {
        send(.welcome(.init(
            proto: LinkVersion(major: LinkProto.major, minor: LinkProto.boxMinor), epoch: "e1",
            host: .init(name: alias, koreVersion: "1", kind: "box"), providers: [],
            policy: .init(sendMaxLevel: .danger, control: .full),
            caps: ["tx", "attn", "commands", "control", "box", LinkFiles.bytesCap] + caps)))
        snapshot()
    }

    private func snapshot() {
        rev += 1
        let windows = served.map { path in
            let tabs = path == folder
                ? chats.enumerated().map { LinkTab(id: "t\($0.offset)", kind: .chat, title: $0.element.title, chatId: $0.element.id) } : []
            return LinkWindow(id: BoxFolder.windowId(path), name: (path as NSString).lastPathComponent, path: path, tabs: tabs, activeTabId: nil)
        }
        let metas = chats.map { chat in
            ChatMeta(
                id: chat.id, provider: "claude", title: chat.title, state: .idle, mode: .init(id: "default", level: .manual), modeIds: ["default"],
                allowedModeIds: ["default"], model: "default", queued: 0, running: false, cards: [], can: .init(send: true, stop: false))
        }
        send(.snapshot(rev: rev, windows: windows, chats: metas))
    }

    private func arrived(_ data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let type = object["t"] as? String else { return }
        if type == "hello" { return welcome() }
        guard type == "cmd", let id = object["id"] as? String, let cmd = object["cmd"] as? [String: Any], let kind = cmd["type"] as? String else { return }
        let path = cmd["path"] as? String
        let provider = cmd["provider"] as? String ?? ""
        switch kind {
        case "fs.list": list(id, path)
        case "fs.watch":
            asked.append("fs.watch")
            send(FilesResult(id: id, ok: true, watching: true))
        case "fs.read": read(id, path ?? "")
        case "fs.create":
            let made = path ?? ""
            let isDir = cmd["dir"] as? Bool == true
            asked.append("fs.create " + (isDir ? "folder " : "") + made)
            if isDir { dirs.insert(made) } else { files[made] = "" }
            send(FilesResult(id: id, ok: true, path: made))
        case "fs.rename":
            let from = cmd["from"] as? String ?? "", to = cmd["to"] as? String ?? ""
            asked.append("fs.rename \(from) → \(to)")
            move(from, to)
            send(FilesResult(id: id, ok: true, path: to))
        case "fs.delete":
            let gone = path ?? ""
            asked.append("fs.delete " + gone)
            files = files.filter { $0.key != gone && !$0.key.hasPrefix(gone + "/") }
            dirs = dirs.filter { $0 != gone && !$0.hasPrefix(gone + "/") }
            send(FilesResult(id: id, ok: true))
        case "fs.mkdir":
            let made = path ?? ""
            asked.append("fs.mkdir " + made)
            dirs.insert(made)
            send(FilesResult(id: id, ok: true, path: made))
        case "fs.search": search(id, root: cmd["root"] as? String ?? folder, query: cmd["query"] as? String ?? "")
        case "folders.list":
            asked.append("folders.list")
            result(id, ["folders": servedList()])
        case "folder.add":
            let added = path ?? ""
            asked.append("folder.add " + added)
            guard dirs.contains(added) else { return result(id, ok: false, ["code": "gone.folder", "message": "Not found"]) }
            if !served.contains(added) { served.append(added) }
            result(id, ["folders": servedList()])
            snapshot()
        case "account.refresh":
            asked.append("account.refresh " + provider)
            let on = signedIn.contains(provider)
            result(id, ["signedIn": on, "message": on ? "Signed in as \(Self.owner)." : "\(provider) isn't signed in."])
        case "account.signIn":
            asked.append("account.signIn " + provider)
            signIns[provider] = id
            let message = provider == "claude"
                ? "Open \(Self.page) and paste the code" : "Open \(Self.devicePage) and enter code \(Self.deviceCode)"
            result(id, ["message": message])
        case "account.cancel":
            asked.append("account.cancel " + provider)
            result(id)
            if let waiting = signIns.removeValue(forKey: provider) {
                result(waiting + HostWire.doneSuffix, ok: false, ["message": "Sign-in cancelled"])
            }
        case "account.submit":
            asked.append("account.submit " + (cmd["input"] as? String ?? ""))
            result(id)
            if let waiting = signIns.removeValue(forKey: provider) {
                signedIn.insert(provider)
                result(waiting + HostWire.doneSuffix, ["signedIn": true, "message": "Signed in as \(Self.owner)."])
            }
        case "fs.stat":
            let at = path ?? ""
            asked.append("fs.stat " + at)
            let answer: @MainActor () -> Void = { [weak self] in self?.stat(id, at) }
            if holdStat { heldStats.append(answer) } else { answer() }
        default:
            // A chat's follow and the rest go unanswered: nothing here needs them.
            asked.append(kind)
        }
    }

    private func servedList() -> [[String: Any]] { served.map { ["path": $0, "windowId": BoxFolder.windowId($0)] } }

    private static func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
    private static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    private func list(_ id: String, _ path: String?) {
        let at = path ?? Self.home
        asked.append("fs.list " + (path ?? "~"))
        guard dirs.contains(at) else { return send(FilesResult.refused(id, .goneFile, "Not there on this box.")) }
        let folders = dirs.filter { $0 != at && Self.parent($0) == at }.sorted().map { FileEntry(name: Self.name($0), kind: .dir) }
        let plain = files.keys.filter { Self.parent($0) == at }.sorted()
            .map { FileEntry(name: Self.name($0), kind: .file, size: Int64(files[$0]?.utf8.count ?? 0)) }
        send(FilesResult(id: id, ok: true, path: at, entries: folders + plain, more: false))
    }

    private func read(_ id: String, _ path: String) {
        asked.append("fs.read " + path)
        guard let text = files[path] else { return send(FilesResult.refused(id, .goneFile, "Not there on this box.")) }
        send(FilesResult(id: id, ok: true, path: path, kind: .text, size: Int64(text.utf8.count), text: text, mtime: 5))
    }

    /// The held `fs.stat` answers, sent now.
    func releaseStat() {
        holdStat = false
        let held = heldStats
        heldStats = []
        for answer in held { answer() }
    }

    /// A folder's files, their bytes and 10 GB free; gone when it isn't a folder here.
    private func stat(_ id: String, _ path: String) {
        guard dirs.contains(path) else { return send(FilesResult.refused(id, .goneFile, "Not there on this box.")) }
        let under = files.filter { $0.key.hasPrefix(path + "/") }
        var answer = FilesResult(id: id, ok: true, path: path, size: Int64(under.values.reduce(0) { $0 + $1.utf8.count }))
        answer.files = under.count
        answer.free = 10_000_000_000
        send(answer)
    }

    private func move(_ from: String, _ to: String) {
        func moved(_ path: String) -> String { path == from ? to : path.hasPrefix(from + "/") ? to + path.dropFirst(from.count) : path }
        files = Dictionary(files.map { (moved($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        dirs = Set(dirs.map(moved))
    }

    private func search(_ id: String, root: String, query: String) {
        asked.append("fs.search \(root) \(query)")
        var hits: [FileHit] = []
        for (path, text) in files.sorted(by: { $0.key < $1.key }) where path.hasPrefix(root + "/") {
            for (index, line) in text.components(separatedBy: "\n").enumerated() where !query.isEmpty && line.localizedCaseInsensitiveContains(query) {
                hits.append(FileHit(path: path, line: index + 1, text: line))
            }
        }
        send(FilesResult(id: id, ok: true, more: false, hits: hits))
    }

    func finish() {
        for workspace in Workspace.all.allObjects where !workspace.isClosed && workspace.boxAlias == alias { workspace.window?.close() }
        pump?.cancel()
        transport = nil
    }
}

// MARK: - Shared steps

/// Presses, clicks or right-clicks an element named only as the step runs (a box chat's tab).
struct DriveTap: Step {
    enum Way { case press, click, rightClick }
    let label: String
    let way: Way
    let id: @MainActor (StoryContext) throws -> StoryID

    init(_ label: String, _ way: Way = .press, _ id: @escaping @MainActor (StoryContext) throws -> StoryID) {
        self.label = label
        self.way = way
        self.id = id
    }

    @MainActor func run(_ story: StoryContext) async throws {
        let target = Locator.id(try id(story))
        switch way {
        case .press: try await Press(target).run(story)
        case .click: try await Click(target).run(story)
        case .rightClick: try await RightClick(target).run(story)
        }
    }
}

/// A click inside an element near its left edge, off whatever sits in its middle (a dimmed
/// window's scrim, its sheet in the centre).
struct DriveClickBeside: Step {
    let label: String
    let target: StoryID

    @MainActor func run(_ story: StoryContext) async throws {
        let element = try await story.element(.id(target))
        guard let window = element.window, let frame = element.frame else {
            throw StoryFailure.elementNotFound(target.raw, nearby: StoryRegistry.nearest(to: target.raw))
        }
        await story.input.click(at: CGPoint(x: frame.minX + 24, y: frame.midY), in: window)
    }
}

/// Kore's questions ("trash") answered yes while the storyline runs, and counted.
@MainActor
final class DriveConfirms: StoryFinishing {
    private(set) var asked: [String] = []

    init() { StorylineSeams.confirm = { [weak self] what in self?.asked.append(what); return true } }

    func finish() { StorylineSeams.confirm = nil }
}
