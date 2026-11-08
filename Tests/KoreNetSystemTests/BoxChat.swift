import Foundation
import HostClient
import KoreHost
import src

/// A box chat's CLI stand-in: each message gets one turn with one tool call and an answer naming it.
@MainActor
final class RelayCLI: ChatBackend {
    let events: AsyncStream<ChatEvent>
    private let sink: AsyncStream<ChatEvent>.Continuation
    var sessionId: String? { "s1" }
    /// The messages the box's CLI got, in order.
    private(set) var sent: [String] = []

    init() { (events, sink) = AsyncStream.makeStream() }

    func start() async throws {}
    func send(_ text: String, files: [Attachments.File], queued: String?, id: String?) async throws -> Bool {
        sent.append(text)
        let turn = "t\(sent.count)"
        sink.yield(.turnStarted(turn, origin: .user, at: Date(timeIntervalSince1970: 0)))
        sink.yield(.toolStarted(ToolCall(id: "w\(sent.count)", name: "mcp__kore_app__kore_whoami", detail: "", input: nil)))
        sink.yield(.toolFinished(id: "w\(sent.count)", output: "ok", isError: false))
        sink.yield(.text("b\(sent.count)", .answer, "Done: \(text)"))
        sink.yield(.turnFinished(turn, .completed, duration: .seconds(5)))
        return true
    }
    func interrupt() async {}
    func respond(to approvalID: String, _ decision: Decision) async {}
    func setMode(_ id: String) async throws {}
    func setPlanMode(_ on: Bool) async {}
    func setModel(_ id: String) async throws {}
    func setEffort(_ level: String) async {}
    func rename(_ title: String) async throws {}
    func stopAgent(_ id: String) async {}
    func agentHistory(_ id: String) async -> [ChatEvent] { [] }
    func fork(message id: String?, text: String) async throws -> ForkStart { .fresh }
    func forkAtEnd() async throws -> ForkStart { .fresh }
    func rollback(message id: String?, text: String) async throws -> (events: [ChatEvent], more: Bool) { ([], false) }
    func earlier() async -> (events: [ChatEvent], more: Bool)? { nil }
    func compact(instructions: String) async throws {}
    func close() async { sink.finish() }

    /// The Mac's chat on a new chat of the box's folder, through `link`.
    static func chat(on link: HostConnection, folder: URL) -> Chat {
        let services = HostServices()
        services.backend = { provider, options in
            let backend = LinkChatBackend(connection: link, provider: provider, folder: folder.path, chatId: nil, model: options.model)
            backend.whoIs = { _, _ in nil }
            backend.usage = { _ in }
            return backend
        }
        return Chat(provider: .claude, folder: folder, modeMemory: ModeMemory(defaults: nil), compactMemory: AutoCompactMemory(defaults: nil), services: services)
    }

    /// The chat's rows of a kind, as shown.
    static func rows(_ chat: Chat, _ kind: TranscriptLog.Entry.Kind) -> [String] {
        chat.transcriptView.entries.filter { $0.kind == kind }.map(\.text)
    }
}
