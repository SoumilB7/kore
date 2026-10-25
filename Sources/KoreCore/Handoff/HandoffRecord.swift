import Foundation

/// What Kore keeps of one handoff, beside the CLIs' own files: where the history came from and
/// up to where, what was carried, and (for a Claude target) the rows Kore wrote, so the chat
/// can show the source's own history in their place and nothing shows twice. A chain of
/// handoffs is these records linked by session id.
public struct HandoffRecord: Codable, Sendable, Equatable {
    /// Goes up when the translation changes what it carries.
    public static let translatorVersion = 1

    public struct Side: Codable, Sendable, Equatable {
        /// The format or CLI id ("claude", "codex").
        public let cli: String
        public let session: String

        public init(cli: String, session: String) {
            self.cli = cli
            self.session = session
        }
    }

    public struct Carried: Codable, Sendable, Equatable {
        public var full: Int
        public var condensed: Int
        public var bare: Int
        public var notCarried: Int
        /// False when a long source's older turns weren't counted.
        public var notCarriedKnown: Bool?
        /// The days the turns not carried span, when known.
        public var notCarriedFrom: Date?
        public var notCarriedTo: Date?
        public var unknown: Int
        public var summary: Bool
        public var tokens: Int
        public var budget: Int

        public init(_ plan: HandoffPlan) {
            full = plan.count(.full)
            condensed = plan.count(.condensed)
            bare = plan.count(.bare)
            notCarried = plan.notCarried
            notCarriedKnown = plan.notCarriedKnown
            notCarriedFrom = plan.notCarriedFrom
            notCarriedTo = plan.notCarriedTo
            unknown = plan.unknown
            summary = plan.summary != nil
            tokens = plan.tokens
            budget = plan.budget
        }
    }

    public let source: Side
    /// The file it was read from.
    public let sourceFile: String
    public let sourceProduct: String
    /// The source's last item at the handoff: its history up to here is what the target holds.
    public let cutoff: String?
    public let sourceTitle: String
    public let sourceModel: String?
    public let target: Side
    public let targetModel: String?
    public let folder: String
    public let at: Date
    public let carried: Carried
    public let translator: Int
    /// Claude target: the uuids of the rows Kore wrote.
    public let written: [String]
    /// Another agent's project instructions, given to this chat at each launch (a Claude chat's
    /// AGENTS.md, a Codex chat's CLAUDE.md): nil when the folder had none, or had the target's own.
    public let instructions: String?

    public init(
        source: Side, sourceFile: URL, sourceProduct: String, cutoff: String?, sourceTitle: String, sourceModel: String?, target: Side, targetModel: String?,
        folder: URL, at: Date = Date(), carried: Carried, written: [String] = [], instructions: String? = nil
    ) {
        self.source = source
        self.sourceFile = sourceFile.path
        self.sourceProduct = sourceProduct
        self.cutoff = cutoff
        self.sourceTitle = sourceTitle
        self.sourceModel = sourceModel
        self.target = target
        self.targetModel = targetModel
        self.folder = folder.path
        self.at = at
        self.carried = carried
        translator = Self.translatorVersion
        self.written = written
        self.instructions = instructions
    }
}

/// The records, one small JSON file per target session in Kore's Application Support
/// (`Kore/handoffs/<target session>.json`). Looked up by the session a chat resumes: the folder
/// is listed once, and a record read only for a session that has one. Blocking file IO, small.
public enum HandoffRecords {
    /// Where they go instead: a storyline run's scratch folder. Nil in Kore.
    package static let root = HostSetting<URL?>(nil)

    static var directory: URL {
        if let root = root.value { return root }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Kore/handoffs")
    }

    private static let lock = NSLock()
    /// The listed folder and the target sessions it holds; records read so far.
    nonisolated(unsafe) private static var listed: (directory: URL, names: Set<String>)?
    nonisolated(unsafe) private static var read: [String: HandoffRecord] = [:]

    /// Saves a new record, and beside it the carried turns as the chat shows them above its
    /// divider (images left out): the source file may be gone or changed by the next time the
    /// chat opens. One already there for that session is an error, never replaced.
    public static func save(_ record: HandoffRecord, history: [HandoffTurn], summary: String? = nil) throws {
        let directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let shown = history.map { turn in
            var turn = turn
            // Small thumbnails, so the chat shows its images again when it opens.
            turn.images = turn.images.compactMap { ImageFit.thumbnail($0) }
            turn.pdfs = nil
            for index in turn.steps.indices { turn.steps[index].images = [] }
            return turn
        }
        try ClaudeHandoffWriter.create(file(record.target.session, in: directory, suffix: ".history"), try encoder.encode(shown))
        if let summary { try ClaudeHandoffWriter.create(file(record.target.session, in: directory, suffix: ".summary", type: "txt"), Data(summary.utf8)) }
        encoder.outputFormatting.insert(.prettyPrinted)
        try ClaudeHandoffWriter.create(file(record.target.session, in: directory), try encoder.encode(record))
        lock.withLock {
            if listed?.directory == directory { listed?.names.insert(record.target.session) }
            read[record.target.session] = record
        }
    }

    /// The record of the handoff that made this session, if Kore made it.
    public static func record(target session: String) -> HandoffRecord? {
        let directory = directory
        let known: Bool = lock.withLock {
            if listed?.directory != directory {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
                listed = (directory, Set(names.filter { $0.hasSuffix(".json") && !$0.hasSuffix(".history.json") }.map { String($0.dropLast(5)) }))
                read = [:]
            }
            return listed?.names.contains(session) == true
        }
        guard known else { return nil }
        if let record = lock.withLock({ read[session] }) { return record }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: file(session, in: directory)),
            let record = try? decoder.decode(HandoffRecord.self, from: data)
        else { return nil }
        lock.withLock { read[session] = record }
        return record
    }

    /// A turn a Codex rollout names no turn for: in a thread Kore made, the history it injected.
    static let untracked = "untracked-"

    /// `segment` with the history Kore carried into it put back in front, when Kore made it
    /// (a chain A → B → C keeps A): its own copy of that history, written rows or injected
    /// items, left out so nothing comes twice.
    public static func chained(_ segment: HandoffSegment) -> HandoffSegment {
        guard let record = record(target: segment.sessionId), let earlier = history(target: segment.sessionId) else { return segment }
        var segment = segment
        let written = Set(record.written)
        segment.turns.removeAll { written.contains($0.id) || ($0.id.hasPrefix(untracked) && record.target.cli == "codex") }
        segment.turns.insert(contentsOf: earlier, at: 0)
        return segment
    }

    /// The turns shown above the divider of the chat this session is (`save`).
    public static func history(target session: String) -> [HandoffTurn]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: file(session, in: directory, suffix: ".history"))).flatMap {
            try? decoder.decode([HandoffTurn].self, from: $0)
        }
    }

    /// The source's summary carried with this session's import, as the model got it.
    public static func summary(target session: String) -> String? {
        (try? Data(contentsOf: file(session, in: directory, suffix: ".summary", type: "txt"))).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func file(_ session: String, in directory: URL, suffix: String = "", type: String = "json") -> URL {
        // Session ids are uuids and thread ids; anything else is kept to a safe name.
        let name = String(session.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        return directory.appendingPathComponent("\(name)\(suffix).\(type)")
    }
}
