/// A recorded session, opened in its folder and read back. Its subclasses name the fixture.
class ResumeStoryline: Storyline {
    override class var isFamily: Bool { self == ResumeStoryline.self }
    /// The `--replay` name of the session.
    class var fixture: String { "" }
    override class var needs: Needs { Needs(folder: .replay(fixture), cli: .real) }

    override func steps() -> [any Step] {
        [
            OpenFolder(), Resume(Self.fixture), WaitForEvent.replay, WaitIdle(),
            // A session that isn't there replays as nothing but a notice: a failure, not a dump.
            Expect("the session's messages") { $0.app.chat?.dumpLines().contains { $0.hasPrefix("user |") } ?? false },
        ]
    }
}

/// verify-landing's Claude replay: the demo chat's rows, compared with the base's.
final class ReplayDumpClaude: ResumeStoryline {
    override class var tags: Set<Tag> { [.resume, .claude, .gate] }
    override class var fixture: String { "claude" }
    override func steps() -> [any Step] { super.steps() + [DumpRows("claude")] }
}

/// verify-landing's Codex replay.
final class ReplayDumpCodex: ResumeStoryline {
    override class var tags: Set<Tag> { [.resume, .codex, .gate] }
    override class var fixture: String { "codex1" }
    override func steps() -> [any Step] { super.steps() + [DumpRows("codex1")] }
}
