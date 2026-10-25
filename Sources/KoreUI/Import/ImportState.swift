import AppKit
import KoreCore
import Observation

/// The import picker's state in one empty chat (chat-handoff.html §2 A): open or not, the
/// chats it offers, the one picked, and the footer's one line. Only the footer changes as you
/// go: picking a row fills the line, a refusal puts its reason there, and Import is on only
/// for a usable pick. Nothing is written until Import.
@MainActor @Observable
final class ImportState {
    /// A chat the picker offers: another agent's chat in this folder, or a file picked or dropped.
    struct Row: Identifiable, Equatable {
        let id: String
        let source: HandoffSource
        /// The provider (or format) whose logo tags it; nil for a file no format knows yet.
        let agent: String?
        let title: String
        let size: String
        let updated: Date?
        /// Its own folder, for the help, when it isn't this one.
        let folder: String?
        /// A chat of this chat's own CLI: offered only when searched for.
        let sameCLI: Bool
        /// It's mid-turn in another tab.
        let running: Bool
    }

    /// The footer's line.
    enum Line: Equatable {
        case empty
        case counting
        case ready(HandoffPreview)
        /// Passed the first-lines check, failed the read: the reason goes in the help only.
        case notImportable(String)
        case sourceBusy
        case signedOut(String)
        case importing(Int)
        case failed(String)
    }

    private(set) var isOpen = false
    /// The search line's text; it shows past `searchFrom` chats.
    var query = ""
    /// The search field has the keys (the popup leaves them to it).
    var searching = false
    private(set) var rows: [Row] = []
    private(set) var picked: String?
    /// The row the keys or the pointer are on: ↑ ↓ move it and Return picks it. One highlight,
    /// apart from the pick's.
    var cursor: String?
    private(set) var line = Line.empty
    /// A chat file is dragged over the empty chat: the line reads "Drop to import".
    var dropTarget = false

    static let searchFrom = 8

    @ObservationIgnored private weak var chat: Chat?
    @ObservationIgnored private weak var workspace: Workspace?
    /// Each pick's own number: a preview that lands after another pick is dropped.
    @ObservationIgnored private var serial = 0

    /// The rows shown: other agents' chats, newest first; this CLI's own only when searched for.
    var shown: [Row] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return rows.filter { !$0.sameCLI } }
        return rows.filter { row in
            let product = row.agent.flatMap { Registry.provider($0)?.usage.product } ?? ""
            return row.title.lowercased().contains(query) || product.lowercased().contains(query)
                || (row.agent ?? "").contains(query)
        }
    }

    /// Whether the picker has anything to list before a search (else a click goes straight to
    /// Choose file…).
    var hasOthers: Bool { rows.contains { !$0.sameCLI } }

    /// Reads the folder's chats (both CLIs' lists, as history has them) and their sizes.
    func load(_ chat: Chat, in workspace: Workspace) async {
        self.chat = chat
        self.workspace = workspace
        if !workspace.loaded { await workspace.refresh() }
        let own = chat.provider.historyAgent
        let sessions = workspace.chats.filter { !$0.archived && $0.id != chat.sessionId }
        let running = Set(sessions.map(\.id).filter { workspace.busy($0) })
        let sizes = await Task.detached { sessions.map { $0.file.flatMap(Self.size) } }.value
        let listed = zip(sessions, sizes).map { session, size in
            Row(
                id: session.id, source: .session(provider: Registry.provider(for: session.agent).id, id: session.id),
                agent: Registry.provider(for: session.agent).id, title: session.title, size: size.map(Self.format) ?? "",
                updated: session.updated, folder: nil, sameCLI: session.agent == own, running: running.contains(session.id))
        }
        // Files picked or dropped stay at the top.
        rows = rows.filter { if case .file = $0.source { true } else { false } } + listed
    }

    func open() {
        isOpen = true
        cursor = nil
        if let picked, !rows.contains(where: { $0.id == picked }) { pick(nil) }
    }

    func close() {
        isOpen = false
        cursor = nil
        searching = false
        query = ""
        if case .importing = line { return }
        if case .failed = line { line = .empty }
    }

    /// ↑ ↓: the cursor to the next row shown or the one before, stopping at the ends; from the
    /// pick when it hasn't moved yet, else from outside the list.
    func moveCursor(_ step: Int) {
        let rows = shown
        guard !rows.isEmpty else { return }
        let from = (cursor ?? picked).flatMap { id in rows.firstIndex { $0.id == id } }
        let index = from.map { min(max($0 + step, 0), rows.count - 1) } ?? (step > 0 ? 0 : rows.count - 1)
        cursor = rows[index].id
    }

    /// Return: picks the cursor's row (never imports); false with no cursor on a row shown.
    func pickCursor() -> Bool {
        guard let cursor, let row = shown.first(where: { $0.id == cursor }) else { return false }
        if row.id != picked { pick(row) }
        return true
    }

    /// A row picked: its preview fills the line (a refusal, its reason). One preview at a time.
    func pick(_ row: Row?) {
        serial += 1
        picked = row?.id
        guard let row, let chat, let workspace else {
            line = .empty
            return
        }
        if case .signedOut(let product) = AccountStore.shared.status(chat.provider.id).signedOut(chat.provider.usage.product) {
            line = .signedOut(product)
            return
        }
        if case .session(_, let id) = row.source, workspace.busy(id) {
            line = .sourceBusy
            return
        }
        line = .counting
        let serial = serial
        Task {
            let result = await workspace.importInspect(row.source, into: chat)
            guard serial == self.serial else { return }
            switch result {
            case .success(let preview):
                line = workspace.busy(preview.sessionId) ? .sourceBusy : .ready(preview)
                presetMode(from: preview, row: row.id, chat: chat)
            case .failure(let error):
                line = .notImportable(error.description)
            }
        }
    }

    /// A file picked or dropped: a row of its own at the top, picked. A file no format knows
    /// gets nothing, quietly.
    func add(file: URL) {
        Task {
            guard let identity = await Task.detached(operation: { HandoffFormats.identify(file, quick: true) }).value else { return }
            let size = await Task.detached { Self.size(file) }.value
            let row = Row(
                id: file.path, source: .file(file), agent: identity.format, title: file.lastPathComponent,
                size: size.map(Self.format) ?? "", updated: nil, folder: file.deletingLastPathComponent().path, sameCLI: false,
                running: false)
            rows.removeAll { $0.id == row.id }
            rows.insert(row, at: 0)
            pick(row)
        }
    }

    /// The row whose source last set the composer's mode: once per pick, so a mode the user
    /// changes after isn't set back.
    private var presetFor: String?

    /// The composer's mode (and plan) as the source last ran, in this CLI's terms: the pill
    /// shows it before the import, to change if wanted.
    private func presetMode(from preview: HandoffPreview, row: String, chat: Chat) {
        guard presetFor != row else { return }
        presetFor = row
        let model = chat.controls.models.first { $0.id == (chat.controls.modelId ?? chat.launchModel) }
        guard let settings = ImportMapping.settings(preview, into: chat.provider, model: model) else { return }
        chat.controls.mode = settings.mode
        chat.controls.planMode = settings.planMode
    }

    var canImport: Bool { if case .ready = line { true } else { false } }

    /// Import: this chat fills in place (the workspace swaps in the imported chat in its tab).
    func importPicked() {
        guard case .ready(let preview) = line, let chat, let workspace, let picked, let row = rows.first(where: { $0.id == picked })
        else { return }
        line = .importing(preview.carried)
        Task {
            let refusal = await workspace.importChat(row.source, into: chat)
            switch refusal {
            case nil:
                isOpen = false
                line = .empty
            case .sourceBusy?: line = .sourceBusy
            case .signedOut(let product)?: line = .signedOut(product)
            case .notImportable?: line = .notImportable("Not a chat Kore can import")
            case .chatInUse?, .folderMissing?: line = .failed(refusal?.reason ?? "")
            case .failed(let why)?: line = .failed(why)
            }
        }
    }

    /// Try again after a failure: the same pick, read again.
    func retry() {
        pick(rows.first { $0.id == picked })
    }

    /// The footer's line as it reads, for checks.
    func text(in chat: Chat) -> String {
        switch line {
        case .empty, .counting: return ""
        case .ready(let preview):
            return [Self.count(preview), Self.tokens(preview), Self.company(preview, into: chat).map { "sent to \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
        case .notImportable: return "Not a chat Kore can import"
        case .sourceBusy: return "Still running in its tab."
        case .signedOut(let product): return "\(product) isn't signed in."
        case .importing(let turns): return "Importing \(turns == 1 ? "1 turn" : "\(turns) turns")…"
        case .failed(let why): return "Couldn't import: \(why)"
        }
    }

    // MARK: Words

    /// "23 turns", "40 of 104 turns", "Summary + 18 turns".
    static func count(_ preview: HandoffPreview) -> String {
        let turns = { (n: Int) in n == 1 ? "1 turn" : "\(n) turns" }
        if preview.summary { return preview.carried == 0 ? "Summary only" : "Summary + " + turns(preview.carried) }
        guard let total = preview.turns else { return "\(preview.carried) recent " + (preview.carried == 1 ? "turn" : "turns") }
        if preview.notCarried > 0 { return "\(preview.carried) of \(turns(total))" }
        return turns(total)
    }

    /// "~84k tokens".
    static func tokens(_ preview: HandoffPreview) -> String {
        preview.tokens < 1000 ? "~\(preview.tokens) tokens" : "~\(Int((Double(preview.tokens) / 1000).rounded()))k tokens"
    }

    /// What goes at each level: "14 in full · 9 condensed · 64 earlier not carried (2–19 Oct)".
    static func breakdown(_ preview: HandoffPreview) -> String {
        var parts: [String] = []
        if preview.summary { parts.append("\(preview.product)'s summary of the earlier turns") }
        if preview.full > 0 { parts.append("\(preview.full) in full") }
        if preview.condensed > 0 { parts.append("\(preview.condensed) condensed") }
        if preview.bare > 0 { parts.append("\(preview.bare) as prompt and reply") }
        if preview.turns == nil {
            parts.append("earlier turns not carried")
        } else if preview.notCarried > 0 {
            parts.append("\(preview.notCarried) earlier not carried" + span(preview.notCarriedFrom, preview.notCarriedTo))
        }
        return parts.joined(separator: " · ")
    }

    /// " (2–19 Oct)", or nothing without dates.
    static func span(_ from: Date?, _ to: Date?) -> String {
        guard let from, let to else { return "" }
        let day = DateFormatter()
        day.setLocalizedDateFormatFromTemplate("d MMM")
        let first = day.string(from: from), last = day.string(from: to)
        return first == last ? " (\(first))" : " (\(first)–\(last))"
    }

    /// Whose model the history goes to, when it leaves the source's company.
    static func company(_ preview: HandoffPreview, into chat: Chat) -> String? {
        guard preview.format != chat.provider.id else { return nil }
        return HandoffWriters.writer(chat.provider.id)?.company
    }

    nonisolated static func size(_ file: URL) -> Int? {
        (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    nonisolated static func format(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

extension AccountStore.Status {
    /// `.signedOut` named by the CLI's product, for the picker's line.
    fileprivate func signedOut(_ product: String) -> ImportState.Line? {
        if case .signedOut = self { return .signedOut(product) }
        return nil
    }
}
