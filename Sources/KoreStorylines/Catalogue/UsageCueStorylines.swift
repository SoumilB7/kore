import AppKit
import Foundation
import KoreCore
import KoreUI

/// The usage mark left of the mode pill (usage-limit-cues.html, option A, as the owner picked
/// it): nothing under 80% of the account's 5-hour limit; "80%" once a turn reports it, "85%" at
/// the next step, and a reading that rounds back to 84.9 changes nothing. Under the pointer its
/// card names the limit and its reset, and its bars become ×. A second window's chat on the same
/// account shows it too; a click in the first hides it in both, kept in the defaults as the
/// step, and 88% keeps it hidden. At 90% it's back in both, and at the limit it reads "100%".
final class UsageMark: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        let mark = StoryID.Composer.usageCue
        return super.steps() + [
            Do("Start with no usage read and nothing dismissed") { _ in StoryUsageCue.reset() },
            ReportUsage(fiveHour: 72, weekly: 40),
            Self.shows(nil),
            Expect("no mark in the composer") { _ in StoryElement(mark) == nil },
            ReportUsage(fiveHour: 80.4, weekly: 40),
            ExpectElement(.id(mark)),
            Self.shows("80%"),
            ReportUsage(fiveHour: 85.1, weekly: 40),
            Self.shows("85%"),
            // Another source rounding lower: the same step.
            ReportUsage(fiveHour: 84.9, weekly: 41),
            Self.shows("85%"),
            // The pointer on it: the card's one line, and × in place of the bars.
            Press(.id(mark.part(.hover))),
            ExpectElement(.id(mark.part(.card))),
            ExpectElement(.id(mark.part(.close))),
            Expect("the card says “5-hour limit 85% · resets …”", found: { story in StoryUsageCue.line(Self.cli(story)) }) { story in
                StoryUsageCue.line(Self.cli(story))?.hasPrefix("5-hour limit 85% · resets ") == true
            },
            Snapshot("usage-mark-hover"),
            OpenSecondChat(),
            Expect("the mark in both windows") { story in Self.marks(story).allSatisfy { $0 } },
            ClickMarkInFirstWindow(),
            Expect("the mark gone from both windows", found: { story in "\(Self.marks(story))" }) { story in
                !Self.marks(story).contains(true)
            },
            Self.shows(nil),
            Expect("the dismissal kept as its step", found: { _ in "\(StoryUsageCue.kept)" }) { _ in StoryUsageCue.kept == [85] },
            ReportUsage(fiveHour: 88, weekly: 41),
            Self.shows(nil),
            ReportUsage(fiveHour: 90.2, weekly: 41),
            Self.shows("90%"),
            Expect("the mark back in both windows", found: { story in "\(Self.marks(story))" }) { story in
                Self.marks(story).allSatisfy { $0 }
            },
            ReportUsage(fiveHour: 100, weekly: 42),
            Self.shows("100%"),
            Snapshot("usage-mark-limit"),
            // Dismissed at the limit, then the 5-hour window resets: the dismissal is over, and a
            // new window that reaches 80% shows again.
            ClickMarkInFirstWindow(),
            Self.shows(nil),
            ReportUsage(fiveHour: 3, weekly: 42, nextWindow: true),
            Self.shows(nil),
            Expect("the reset dropped the dismissal", found: { _ in "\(StoryUsageCue.kept)" }) { _ in StoryUsageCue.kept.isEmpty },
            ReportUsage(fiveHour: 81, weekly: 42, nextWindow: true),
            Self.shows("80%"),
            CloseSecondWindow(),
            Do("Leave no usage behind") { _ in StoryUsageCue.reset() },
        ]
    }

    static func cli(_ story: StoryContext) -> String { story.variant?.provider ?? "claude" }

    /// The mark's short form, or none.
    static func shows(_ text: String?) -> Expect {
        Expect(text.map { "the mark to read “\($0)”" } ?? "no mark", found: { story in StoryUsageCue.mark(cli(story)) ?? "none" }) { story in
            StoryUsageCue.mark(cli(story)) == text
        }
    }

    /// Whether each window's composer has the mark: the storyline's, then the second one's.
    static func marks(_ story: StoryContext) -> [Bool] {
        [story.window, OpenSecondChat.window(story)].map { window in
            window.map { StoryElement(StoryID.Composer.usageCue, in: $0) != nil } ?? false
        }
    }
}

/// A turn's report of the account's limits, as the CLI streams it during a turn: both windows,
/// their resets fixed for the storyline.
struct ReportUsage: Step {
    let fiveHour: Double
    let weekly: Double
    /// The 5-hour window after this one (its reset 5 hours later): a reset happened.
    var nextWindow = false
    var label: String {
        "A turn reports the 5-hour limit at \(fiveHour)%\(nextWindow ? " in a new window" : ""), the week at \(weekly)%"
    }

    static let fiveHourResets = Date().addingTimeInterval(2 * 3600).rounded
    static let weeklyResets = Date().addingTimeInterval(4 * 86400).rounded

    func run(_ story: StoryContext) async throws {
        let fiveHourResets = nextWindow ? Self.fiveHourResets.addingTimeInterval(5 * 3600) : Self.fiveHourResets
        StoryUsageCue.report(
            UsageMark.cli(story), fiveHour: fiveHour, weekly: weekly, fiveHourResets: fiveHourResets,
            weeklyResets: Self.weeklyResets)
    }
}

/// Another folder in its own window, with a chat of the same CLI.
struct OpenSecondChat: Step {
    var label: String { "Open another folder in a second window, with a chat" }
    var timeout: Duration? { .seconds(15) }

    @MainActor static func folder(_ story: StoryContext) -> URL { story.outputs.appendingPathComponent("folders/\(story.name)-second", isDirectory: true) }

    @MainActor static func workspace(_ story: StoryContext) -> Workspace? {
        let path = folder(story).resolvingSymlinksInPath().path
        return Workspace.all.allObjects.first { $0.folder.resolvingSymlinksInPath().path == path && $0.window?.isVisible == true }
    }

    @MainActor static func window(_ story: StoryContext) -> NSWindow? { workspace(story)?.window }

    func run(_ story: StoryContext) async throws {
        guard let model = AppModel.shared else { throw StoryFailure.other("the app model isn't up") }
        let folder = Self.folder(story)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.openFolder(folder)
        let workspace = try await story.wait("the second window") { Self.workspace(story) }
        workspace.window?.setContentSize(story.windowSize)
        guard workspace.start(provider: UsageMark.cli(story), model: nil) else { throw StoryFailure.modelMissing("the provider") }
        _ = try await story.wait("the second window's chat") { workspace.activeTab.chat }
        try await story.until("the second window's composer") {
            guard let window = workspace.window else { return false }
            return StoryElement(StoryID.Composer.field, in: window) != nil
        }
    }
}

/// A click on the first window's mark, with the second window's still there.
struct ClickMarkInFirstWindow: Step {
    var label: String { "Click the mark in the first window" }

    func run(_ story: StoryContext) async throws {
        guard let window = story.window else { throw StoryFailure.other("the first window isn't open") }
        let element = try await story.wait("the first window's mark") { StoryElement(StoryID.Composer.usageCue, in: window) }
        try await story.input.click(element)
    }
}

struct CloseSecondWindow: Step {
    var label: String { "Close the second window" }

    func run(_ story: StoryContext) async throws {
        guard let window = OpenSecondChat.window(story) else { return }
        window.close()
        try await story.until("the second window to close") { !window.isVisible }
    }
}

extension Date {
    /// To the whole second, as a CLI gives a reset.
    fileprivate var rounded: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded()) }
}
