import Foundation

/// One CLI's side of an import: the neutral form into that CLI's own history, so a chat of it
/// can resume it. A new target CLI is one type conforming to this, plus a line in
/// `HandoffWriters.all`.
public protocol HandoffWriter: Sendable {
    /// The provider id of the chats it writes for ("claude", "codex").
    var id: String { get }
    var product: String { get }
    /// The project instruction files this CLI reads by itself.
    var instructionFiles: [String] { get }
    /// The target model's context window, for the budget.
    func window(model: String?) -> Int
    /// Writes the history as a new session; nothing of an existing one is touched.
    func write(_ plan: HandoffPlan, into target: HandoffTarget) async throws -> HandoffWritten
}

/// The new chat the history goes into.
public struct HandoffTarget: Sendable {
    public let folder: URL
    public let title: String
    public let model: String?
    public let effort: String?
    /// The target provider's mode id.
    public let mode: String
    public let planMode: Bool
    /// Another agent's instruction file to give the chat, the folder having none of its own.
    public let instructions: URL?

    public init(folder: URL, title: String, model: String?, effort: String?, mode: String, planMode: Bool, instructions: URL?) {
        self.folder = folder
        self.title = title
        self.model = model
        self.effort = effort
        self.mode = mode
        self.planMode = planMode
        self.instructions = instructions
    }
}

public struct HandoffWritten: Sendable {
    /// What the target CLI resumes.
    public let session: String
    /// Rows Kore wrote into a history the CLI shows as its own (a Claude transcript), to hide
    /// where the source's own history is shown instead; empty when the CLI shows none (Codex).
    public let rows: [String]

    public init(session: String, rows: [String] = []) {
        self.session = session
        self.rows = rows
    }
}

/// The CLIs Kore can import into.
public enum HandoffWriters {
    public static let all: [any HandoffWriter] = [ClaudeHandoffWriter(), CodexHandoffWriter()]

    /// Writers used in place of a CLI's own: a storyline run's scripted CLI. Empty in Kore.
    package static let standIns = HostSetting<[String: any HandoffWriter]>([:])

    public static func writer(_ id: String) -> (any HandoffWriter)? {
        standIns.value[id] ?? all.first { $0.id == id }
    }

    /// Another agent's instruction file for a chat of `writer`'s CLI in `folder`: only when the
    /// folder has none of that CLI's own (it reads those itself, and the folder is left as is).
    public static func instructions(for writer: any HandoffWriter, in folder: URL) -> URL? {
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }
        guard !writer.instructionFiles.contains(where: exists) else { return nil }
        let others = all.filter { $0.id != writer.id }.flatMap(\.instructionFiles)
        return others.first(where: exists).map { folder.appendingPathComponent($0) }
    }

    /// An instruction file's text for a CLI that takes it as text, up to 64 KB.
    public static func instructionText(_ file: URL) -> String? {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        return "Project instructions from \(file.lastPathComponent) in this folder:\n\n" + String(decoding: data.prefix(64 << 10), as: UTF8.self)
    }
}
