import Foundation
import KoreCore
import LinkProtocol

/// The box's Claude accounts: the default one (`~/.claude`, or `CLAUDE_CONFIG_DIR` as kore-host
/// was started) and each folder of `~/.config/claude-accounts`, a config folder of its own that
/// the owner signed in there. A chat runs on one of them (`CLAUDE_CONFIG_DIR` at its CLI's
/// start); a folder keeps the one its new chats start on. Read only when a client asks (the
/// Account popup opening), never on a timer: one `claude auth status` per account. Kore never
/// signs an account in or out here and never reads a token. Before a chat or a usage read runs
/// in an account's folder, the default's chats and settings are linked into it where it has
/// none (`CLIProfiles.linkShared`): only links are added, its own files are never touched.
/// Codex keeps its one login on a box.
@MainActor
package final class HostAccounts {
    /// Where the added accounts are: a folder each, by name.
    package let root: URL
    /// The default account's folder.
    package let main: URL
    /// `claude auth status --json` with `CLAUDE_CONFIG_DIR` at a folder (nil: the default's).
    /// Tests answer for it.
    package var status: @Sendable (URL?) async throws -> JSONValue = { folder in
        try await HostAccounts.pinned(folder) { try await ClaudeAuth.statusReply() }
    }
    /// An account's plan and limits: a message-less `claude -p` there (`get_usage`).
    package var usage: @Sendable (URL?) async throws -> PlanReading = { folder in
        try await HostAccounts.pinned(folder) { try await PlanUsage.claude() }
    }
    package var now: () -> Date = { Date() }
    /// A list read this recently is answered again as it is: an open and close of the popup
    /// doesn't run the CLI five times more.
    package static let fresh: TimeInterval = 30

    /// Each folder's account for new chats (`accounts.json` in kore-host's state).
    private let file: URL
    private var defaults: [String: String]
    private var read: (at: Date, accounts: [LinkAccount])?
    private var reading: Task<[LinkAccount], Never>?
    /// A login paused for a move (`HostLoginMoves`): nothing starts on it.
    package var paused: (String) -> Bool = { _ in false }

    /// The accounts as last listed (none before a list).
    package var lastListed: [LinkAccount] { read?.accounts ?? [] }

    /// The next list reads every account again (one came, or went).
    package func forget() { read = nil }

    /// Whether `claude auth status` reads the login in `folder` signed in.
    package func signedIn(folder: URL) async -> Bool {
        guard let reply = try? await status(folder) else { return false }
        return ClaudeAuth.Status(reply).loggedIn
    }

    package init(home: URL, environment: [String: String], state: URL) {
        root = home.appendingPathComponent(".config/claude-accounts", isDirectory: true)
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            main = URL(fileURLWithPath: dir, isDirectory: true)
        } else {
            main = home.appendingPathComponent(".claude", isDirectory: true)
        }
        file = state.appendingPathComponent("accounts.json")
        defaults = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }?.folders ?? [:]
    }

    private struct Saved: Codable { var folders: [String: String] }

    /// Runs `body` with the CLI's `CLAUDE_CONFIG_DIR` at `folder` (nil: as kore-host has it).
    nonisolated static func pinned<T: Sendable>(_ folder: URL?, _ body: @Sendable () async throws -> T) async throws -> T {
        guard let folder else { return try await body() }
        return try await CLIProfiles.$pinned.withValue(CLIProfiles.Pin(cli: "claude", folder: folder)) { try await body() }
    }

    // MARK: Which accounts

    /// "main", then each added account's folder name in order. A name the link can't carry, or
    /// "main" itself, isn't listed.
    package func ids() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let added = names.filter { name in
            var isDir: ObjCBool = false
            return name != LinkAccount.main && !name.hasPrefix(".") && LinkPolicy.plainID(name)
                && FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue
        }
        return [LinkAccount.main] + added.sorted()
    }

    /// An added account's folder while it's there; nil for the default, or one that's gone.
    package func folder(_ id: String) -> URL? {
        guard id != LinkAccount.main, ids().contains(id) else { return nil }
        return root.appendingPathComponent(id, isDirectory: true)
    }

    package func exists(_ id: String) -> Bool { id == LinkAccount.main || folder(id) != nil }

    /// Every account and who it is, each read in its own folder, at most three CLIs at once. A
    /// read under way is joined; one in the last `fresh` seconds is answered as it is.
    package func list(fresh: Bool = false) async -> [LinkAccount] {
        if !fresh, let read, now().timeIntervalSince(read.at) < Self.fresh, read.accounts.map(\.id) == ids() { return read.accounts }
        if let reading { return await reading.value }
        let ids = ids()
        // `auth status` writes nothing: no links are made for a read.
        let folders = ids.map { ($0, $0 == LinkAccount.main ? nil : root.appendingPathComponent($0, isDirectory: true)) }
        let status = status
        // A login paused for a move isn't read: its CLI could refresh it while the other device
        // already holds the copy that's going to be the one.
        let paused = Set(ids.filter { self.paused($0) })
        let task = Task { () -> [LinkAccount] in
            var out: [String: LinkAccount] = [:]
            for chunk in stride(from: 0, to: folders.count, by: 3).map({ Array(folders[$0..<min($0 + 3, folders.count)]) }) {
                await withTaskGroup(of: LinkAccount.self) { group in
                    for (id, dir) in chunk {
                        group.addTask {
                            if paused.contains(id) { return LinkAccount(id: id) }
                            var account = Self.account(id, reply: try? await status(dir))
                            // Moved here and not used yet: where it came from.
                            if let dir, let from = HostLoginMoves.from(dir), from.used != true { account.from = from.host }
                            return account
                        }
                    }
                    for await account in group { out[account.id] = account }
                }
            }
            return ids.compactMap { out[$0] }
        }
        reading = task
        let accounts = await task.value
        reading = nil
        read = (now(), accounts)
        return accounts
    }

    /// An account as `claude auth status --json` said it; nil: it couldn't be read.
    nonisolated static func account(_ id: String, reply: JSONValue?) -> LinkAccount {
        guard let reply else { return LinkAccount(id: id) }
        let status = ClaudeAuth.Status(reply)
        return LinkAccount(
            id: id, email: status.loggedIn ? status.email : nil, organization: status.loggedIn ? status.orgName : nil,
            plan: status.loggedIn ? PlanReading.claudePlan(status.subscriptionType) : nil, signedIn: status.loggedIn)
    }

    // MARK: A chat's account

    package enum Failure: LocalizedError {
        case gone(String)
        case moving(String)
        package var errorDescription: String? {
            switch self {
            case .gone(let id): "The Claude account “\(id)” isn't on this machine any more. Pick another in Account."
            case .moving(let id): "The Claude account “\(id)” is moving to another device. Pick another in Account."
            }
        }
    }

    /// What a CLI on `id` starts with: nothing for the default; else `CLAUDE_CONFIG_DIR` at its
    /// folder, its shared entries linked first. Throws when its folder is gone: the chat never
    /// falls back to another account by itself.
    package func environment(_ id: String?) throws -> [String: String] {
        if paused(id ?? LinkAccount.main) { throw Failure.moving(id ?? LinkAccount.main) }
        guard let id, id != LinkAccount.main else { return [:] }
        guard let dir = folder(id) else { throw Failure.gone(id) }
        prepare(dir)
        HostLoginMoves.markUsed(dir)
        return ["CLAUDE_CONFIG_DIR": dir.path]
    }

    /// The default's chats, settings and skills, linked where the account has none: a chat
    /// resumes on any account, and its sessions stay where the box's history reads them.
    private func prepare(_ dir: URL) {
        CLIProfiles.linkShared("claude", into: dir, from: main)
    }

    /// One account's plan and limits.
    package func usage(_ id: String) async throws -> PlanReading {
        guard exists(id) else { throw Failure.gone(id) }
        if paused(id) { throw Failure.moving(id) }
        let dir = folder(id)
        if let dir { prepare(dir) }
        return try await usage(dir)
    }

    /// One account's status, read in its folder.
    package func status(_ id: String) async throws -> JSONValue {
        guard exists(id) else { throw Failure.gone(id) }
        if paused(id) { throw Failure.moving(id) }
        return try await status(folder(id))
    }

    // MARK: A folder's default

    /// The account new chats in `folder` start on; nil for the default.
    package func folderDefault(_ folder: String) -> String? {
        defaults[folder].flatMap { exists($0) && $0 != LinkAccount.main ? $0 : nil }
    }

    package func setFolderDefault(_ folder: String, _ id: String) {
        let value: String? = id == LinkAccount.main ? nil : id
        guard defaults[folder] != value else { return }
        defaults[folder] = value
        guard let data = try? JSONEncoder().encode(Saved(folders: defaults)) else { return }
        do { try HostPaths.privateFile(data, to: file) } catch { HostJournal.writeFailed(file, HostJournal.code(error)) }
    }
}
