import Foundation

/// Model requests Kore's chats on a box made (link 1.5): the box forwards each request's tokens in
/// its chat's events, and the Mac keeps them here, weighed, so Kore's share of the plan's limits
/// counts the box's work as Kore's. The box keeps no record of its own. Each request once, keyed
/// by its chat and its own id (copies of one keep the larger weight); a week is kept, in
/// `usage/forwarded.json` next to the index.
public struct ForwardedRequest: Codable, Sendable, Equatable {
    public var cli: String
    /// The box's chat, as "<box>/<chat id>".
    public var chat: String
    public var request: String
    public var time: Date
    public var model: String
    public var agent: String?
    public var units: Double
    /// The chat's title on the box when it was made, so the ledger names it with the box offline.
    public var title: String?
    /// The box CLI's login (`PlanSnapshot.account`) when it was made; nil while unknown.
    public var account: String?

    public init(
        cli: String, chat: String, request: String, time: Date, model: String, agent: String?, units: Double, title: String? = nil,
        account: String? = nil
    ) {
        self.cli = cli
        self.chat = chat
        self.request = request
        self.time = time
        self.model = model
        self.agent = agent
        self.units = units
        self.title = title
        self.account = account
    }

    var key: String { chat + "|" + request }

    /// The box's alias, from "<box>/<chat id>".
    public var box: String { Self.box(chat) ?? chat }

    static func box(_ chat: String) -> String? { chat.firstIndex(of: "/").map { String(chat[..<$0]) } }
}

extension KoreUsage {
    /// Notes a box chat's request, with the box CLI's login when it's known; a copy already
    /// noted keeps the larger weight.
    public func forwarded(_ request: ForwardedRequest) {
        loadForwarded()
        var request = request
        if request.account == nil { request.account = boxLogins[request.box + "/" + request.cli] }
        if let kept = forwardedRequests[request.key] {
            request.title = request.title ?? kept.title
            request.account = request.account ?? kept.account
            guard request.units > kept.units || (request.title, request.account) != (kept.title, kept.account) else { return }
            request.units = max(request.units, kept.units)
        }
        forwardedRequests[request.key] = request
        let cutoff = Date().addingTimeInterval(-8 * 86400)
        forwardedRequests = forwardedRequests.filter { $0.value.time > cutoff }
        saveForwarded()
    }

    /// Who a box's CLI is signed in as (an email, as the box said it): requests noted from now
    /// on carry it, and those noted before without one are taken as its.
    public func boxLogin(box: String, cli: String, email: String?) {
        guard let account = PlanSnapshot.account(email: email), boxLogins[box + "/" + cli] != account else { return }
        boxLogins[box + "/" + cli] = account
        loadForwarded()
        let unstamped = forwardedRequests.filter { $0.value.account == nil && $0.value.cli == cli && $0.value.box == box }.keys
        guard !unstamped.isEmpty else { return }
        for key in unstamped { forwardedRequests[key]?.account = account }
        saveForwarded()
    }

    /// The box chats' requests for `cli` since `since`, as Kore's: those whose box CLI was
    /// signed in to `account` (the plan reading's login). With either login unknown, as this
    /// Mac's CLI on its own counts: only for the main login (`main`).
    func forwardedRequests(cli: String, since: Date, account: String? = nil, main: Bool = true) -> [UsageRequest] {
        loadForwarded()
        return forwardedRequests.values.filter { request in
            guard request.cli == cli, request.time >= since else { return false }
            guard let account, let login = request.account ?? boxLogins[request.box + "/" + cli] else { return main }
            return login == account
        }
        .sorted { $0.time < $1.time }
        .map { UsageRequest(time: $0.time, chat: $0.chat, agent: $0.agent, folder: nil, model: $0.model, units: $0.units, kore: true) }
    }

    /// Each box chat's alias and latest title, by its id in the ledger.
    func forwardedChats() -> [String: (box: String, title: String?)] {
        loadForwarded()
        var out: [String: (box: String, title: String?, at: Date)] = [:]
        for request in forwardedRequests.values {
            var chat = out[request.chat] ?? (request.box, nil, .distantPast)
            if let title = request.title, request.time >= chat.at { (chat.title, chat.at) = (title, request.time) }
            out[request.chat] = chat
        }
        return out.mapValues { ($0.box, $0.title) }
    }

    /// A box's stores moved from `old` (its alias) to `new` (its KoreNet id): the requests kept
    /// in memory and the logins known for it move too, so nothing writes the old key back.
    public func rekeyBox(from old: String, to new: String) {
        guard old != new else { return }
        loadForwarded()
        let prefix = old + "/"
        var changed = false
        for (key, request) in forwardedRequests where request.chat.hasPrefix(prefix) {
            var moved = request
            moved.chat = new + "/" + request.chat.dropFirst(prefix.count)
            forwardedRequests[key] = nil
            changed = true
            if let kept = forwardedRequests[moved.key], kept.units >= moved.units { continue }
            forwardedRequests[moved.key] = moved
        }
        for (key, login) in boxLogins where key.hasPrefix(prefix) {
            boxLogins[key] = nil
            boxLogins[new + "/" + key.dropFirst(prefix.count)] = login
        }
        if changed { saveForwarded() }
    }

    private var forwardedFile: URL? { forwardedSupport?.appendingPathComponent("forwarded.json") }

    private func loadForwarded() {
        guard !forwardedLoaded else { return }
        forwardedLoaded = true
        guard let file = forwardedFile, let data = try? Data(contentsOf: file),
            let list = try? JSONDecoder().decode([ForwardedRequest].self, from: data)
        else { return }
        forwardedRequests = Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { a, b in a.units >= b.units ? a : b })
    }

    private func saveForwarded() {
        guard let file = forwardedFile, let data = try? JSONEncoder().encode(Array(forwardedRequests.values)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
