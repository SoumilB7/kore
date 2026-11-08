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

    public init(cli: String, chat: String, request: String, time: Date, model: String, agent: String?, units: Double) {
        self.cli = cli
        self.chat = chat
        self.request = request
        self.time = time
        self.model = model
        self.agent = agent
        self.units = units
    }

    var key: String { chat + "|" + request }
}

extension KoreUsage {
    /// Notes a box chat's request; a copy already noted keeps the larger weight.
    public func forwarded(_ request: ForwardedRequest) {
        loadForwarded()
        if let kept = forwardedRequests[request.key], kept.units >= request.units { return }
        forwardedRequests[request.key] = request
        let cutoff = Date().addingTimeInterval(-8 * 86400)
        forwardedRequests = forwardedRequests.filter { $0.value.time > cutoff }
        saveForwarded()
    }

    /// The box chats' requests for `cli` since `since`, as Kore's.
    func forwardedRequests(cli: String, since: Date) -> [UsageRequest] {
        loadForwarded()
        return forwardedRequests.values.filter { $0.cli == cli && $0.time >= since }.sorted { $0.time < $1.time }.map {
            UsageRequest(time: $0.time, chat: $0.chat, agent: $0.agent, folder: nil, model: $0.model, units: $0.units, kore: true)
        }
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
