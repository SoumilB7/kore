import Foundation

/// The carried history into a new Codex thread: `thread/start`, its name, then the history as
/// Responses items (`thread/inject_items`), which Codex writes to the rollout at once and the
/// model sees from the next turn. No turn runs until the user sends one. Only plain messages
/// are written: a reasoning or compaction item would need encrypted content, and a forged one
/// fails the thread's next turn.
public struct CodexHandoffWriter: HandoffWriter {
    public let id = "codex"
    public let product = "Codex"
    public let company = "OpenAI"
    /// Measured: an imported thread's first gpt-6-luna turn read 81,174 tokens over a 57,621
    /// estimate (2026-10-24).
    public let overhead = 23_000
    public let instructionFiles = ["AGENTS.md"]

    public init() {}

    public func window(model: String?) -> Int { HandoffBudget.codexWindow }

    public func write(_ plan: HandoffPlan, into target: HandoffTarget) async throws -> HandoffWritten {
        let options = CodexSession.Options(
            cwd: target.folder, model: target.model, effort: target.effort,
            permissions: CodexSession.Permissions(rawValue: target.mode) ?? .askForApproval, plan: target.planMode,
            developerInstructions: target.instructions.flatMap(HandoffWriters.instructionText))
        return HandoffWritten(session: try await Self.open(plan, options: options, title: target.title))
    }

    /// One developer note, the source's summary as a user message, then per turn the user's
    /// message and one assistant message per step, then the reply.
    public static func items(_ plan: HandoffPlan, folder: URL? = nil) -> [JSONValue] {
        var items: [JSONValue] = [message("developer", [text(HandoffRender.note(plan, folder: folder), output: false)])]
        if let summary = plan.summary {
            items.append(message("user", [text(HandoffRender.summary(summary, from: plan.product), output: false)]))
        }
        if let requests = HandoffRender.requests(plan.earlierRequests ?? []) {
            items.append(message("user", [text(requests, output: false)]))
        }
        for entry in plan.entries {
            let turn = HandoffRender.turn(entry.turn, entry.level)
            let images: [JSONValue] = turn.images.map { ["type": "input_image", "image_url": .string($0.dataURL)] }
            items.append(message("user", [text(turn.user, output: false)] + images))
            for block in turn.assistant { items.append(message("assistant", [text(block, output: true)])) }
        }
        return items
    }

    /// Makes the thread on an app-server of its own, closed after, so the chat that continues
    /// it can resume it (a thread has one writer at a time). Returns its id.
    static func open(_ plan: HandoffPlan, options: CodexSession.Options, title: String) async throws -> String {
        let session = try await CodexSession.start(options)
        do {
            let thread = await session.threadId
            try await session.rename(title)
            try await session.inject(items(plan, folder: options.cwd))
            await session.close()
            return thread
        } catch {
            await session.close()
            throw error
        }
    }

    private static func message(_ role: String, _ content: [JSONValue]) -> JSONValue {
        ["type": "message", "role": .string(role), "content": .array(content)]
    }

    private static func text(_ text: String, output: Bool) -> JSONValue {
        ["type": output ? "output_text" : "input_text", "text": .string(text)]
    }
}
