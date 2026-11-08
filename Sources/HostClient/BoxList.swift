import Foundation
import Observation

/// The boxes this Mac lists: the hosts whose kore-host has answered once, and the ones added by
/// hand, each with what a probe last found and its folders. Nothing dials until a box is asked
/// about (its row opened): never on a timer. The other SSH hosts are suggestions for adding one.
@MainActor @Observable
package final class BoxList {
    package enum Status: Equatable, Sendable {
        /// Not probed this run.
        case unknown
        case probing
        /// kore-host answered.
        case ready
        /// SSH worked, but there's no kore-host on the box.
        case notSetUp
        /// SSH or kore-host didn't answer, or turned this Mac away.
        case unreachable(String)
    }

    package struct Box: Identifiable, Equatable, Sendable {
        package var alias: String
        package var status = Status.unknown
        package var folders: [BoxFolder] = []
        package var id: String { alias }
    }

    package private(set) var boxes: [Box] = []

    package static let shared = BoxList()

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let hosts: () -> [String]
    @ObservationIgnored private let connection: @MainActor (String) -> HostConnection
    @ObservationIgnored private var probes: [String: Task<Void, Never>] = [:]
    /// How long a probe waits for kore-host's state.
    @ObservationIgnored package var patience: Duration = .seconds(20)

    private static let listedKey = "boxHosts"
    /// Boxes that answered on this Mac before the list was kept.
    private static let seed = ["mybox"]

    package init(
        defaults: UserDefaults? = .standard, hosts: @escaping () -> [String] = { SSHHosts.aliases() },
        connection: @escaping @MainActor (String) -> HostConnection = { HostConnection.named($0) }
    ) {
        self.defaults = defaults
        self.hosts = hosts
        self.connection = connection
        if let defaults, defaults.stringArray(forKey: Self.listedKey) == nil { defaults.set(Self.seed, forKey: Self.listedKey) }
        reload()
    }

    private var listed: [String] { defaults?.stringArray(forKey: Self.listedKey) ?? [] }

    /// The list again from what's kept; what's known of each box stays.
    package func reload() {
        let old = Dictionary(boxes.map { ($0.alias, $0) }, uniquingKeysWith: { a, _ in a })
        boxes = listed.map { alias in
            var box = old[alias] ?? Box(alias: alias)
            if box.folders.isEmpty { box.folders = HostCache(alias: alias).state()?.folders ?? [] }
            return box
        }
    }

    /// SSH hosts not listed yet, for Add a box…, those starting with `typed` first.
    package func suggestions(_ typed: String = "") -> [String] {
        let shown = Set(listed)
        let typed = typed.trimmingCharacters(in: .whitespaces).lowercased()
        let rest = hosts().filter { !shown.contains($0) }
        return typed.isEmpty ? rest : rest.filter { $0.lowercased().hasPrefix(typed) } + rest.filter { !$0.lowercased().hasPrefix(typed) && $0.lowercased().contains(typed) }
    }

    /// Add a box…: listed from now on, answered or not.
    package func add(_ alias: String) {
        let alias = alias.trimmingCharacters(in: .whitespaces)
        guard !alias.isEmpty, !alias.contains(" ") else { return }
        if !listed.contains(alias) { defaults?.set(listed + [alias], forKey: Self.listedKey) }
        if box(alias) == nil { boxes.append(Box(alias: alias)) }
    }

    package func box(_ alias: String) -> Box? { boxes.first { $0.alias == alias } }

    /// Dials the box's kore-host once: its state and folders, then the link closes unless a window
    /// holds it. A probe already under way is the one waited on.
    package func probe(_ alias: String) async {
        if let running = probes[alias] { return await running.value }
        let task = Task { await run(alias) }
        probes[alias] = task
        await task.value
        probes[alias] = nil
    }

    /// A folder already on the box, added to what it serves.
    package func addFolder(_ alias: String, path: String) async -> Result<BoxFolder, HostRefusal> {
        await linked(alias) { connection in
            let result = await connection.addFolder(path)
            if case .success = result { self.update(alias) { $0.folders = connection.folders } }
            return result
        } ?? .failure(HostRefusal(message: "Can't reach \(alias)"))
    }

    private func run(_ alias: String) async {
        update(alias) { $0.status = .probing }
        let folders: [BoxFolder]? = await linked(alias) { await $0.listFolders() }
        if let folders {
            update(alias) {
                $0.status = .ready
                $0.folders = folders
            }
        }
    }

    /// Runs `work` while the box is linked (dialling it if no window holds it), or says why it
    /// can't be: nil then, the status set.
    private func linked<T>(_ alias: String, _ work: (HostConnection) async -> T) async -> T? {
        let connection = connection(alias)
        connection.retain()
        defer { connection.release() }
        let end = ContinuousClock.now + patience
        while ContinuousClock.now < end, !connection.isOnline, connection.phase != .offline {
            if case .refused = connection.phase { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard connection.isOnline else {
            let status: Status =
                if case .refused(let why) = connection.phase { .unreachable(why) }
                else if connection.hostMissing { .notSetUp }
                else { .unreachable("Can't reach \(alias)") }
            update(alias) { $0.status = status }
            return nil
        }
        return await work(connection)
    }

    private func update(_ alias: String, _ change: (inout Box) -> Void) {
        guard let i = boxes.firstIndex(where: { $0.alias == alias }) else { return }
        change(&boxes[i])
    }
}
