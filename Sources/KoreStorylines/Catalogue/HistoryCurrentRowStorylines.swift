import AppKit
import Foundation
import KoreUI
import src

/// History's highlight (owner's pick C, 2026-11-24): the chat open in this tab is the current row:
/// raised (#263036) with its name in light blue, kept while History is open. The pointer's row
/// (or the keys') takes a faint accent tint, and the current row stays raised beside it. Fills
/// only. Read off the window's picture at each row's own frame.
final class HistoryCurrentRow: ChatStoryline {
    override class var tags: Set<Tag> { [.gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Ready.")]) }

    /// A row's fill, read just inside its leading edge, mid-height (left of the logo).
    private struct Fill: Step {
        let what: String
        let session: @MainActor (StoryContext) throws -> String
        /// The raised fill (the current row), else the accent tint (the pointer's row).
        let raised: Bool
        /// A plain row beside it: the raised fill is lighter than its ground.
        var ground: (@MainActor (StoryContext) throws -> String)? = nil
        var label: String { "History: \(what) \(raised ? "raised" : "tinted, not raised")" }
        var timeout: Duration? { .seconds(10) }

        @MainActor func run(_ story: StoryContext) async throws {
            var found = ""
            do {
                try await story.until(label, timeout: .seconds(3)) {
                    guard let row = StoryElement(StoryID.History.row(try session(story)))?.frame,
                        let color = Self.color(at: CGPoint(x: row.minX + 3, y: row.midY), story)
                    else { return false }
                    let (r, g, b) = (Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
                    found = String(format: "#%02X%02X%02X", r, g, b)
                    // The raised fill is a neutral grey (#263036, a step up under the pointer or
                    // pressed); the tint is the ground with the accent's blue in it. Judged by hue,
                    // not exact values: the panel's ground differs with the window's state.
                    var lighter = r >= 0x24
                    if let ground, let plain = StoryElement(StoryID.History.row(try ground(story)))?.frame,
                        let under = Self.color(at: CGPoint(x: plain.minX + 3, y: plain.midY), story) {
                        let base = Int(under.redComponent * 255)
                        found += String(format: " over #%02X%02X%02X", base, Int(under.greenComponent * 255), Int(under.blueComponent * 255))
                        lighter = r >= base + 4
                    }
                    let neutral = b - r <= 20 && lighter
                    return raised ? neutral : b - r >= 22 && !(b - r <= 20)
                }
            } catch StoryFailure.timedOut {
                throw StoryFailure.expectation("\(what)'s fill \(found.isEmpty ? "unread" : found)")
            }
        }

        @MainActor static func color(at point: CGPoint, _ story: StoryContext) -> NSColor? {
            guard let window = story.window, let png = snapshot(window), let picture = NSBitmapImageRep(data: png) else { return nil }
            let scale = CGFloat(picture.pixelsWide) / window.frame.width
            let (px, py) = (Int(point.x * scale), Int((window.frame.height - point.y) * scale))
            guard px >= 0, py >= 0, px < picture.pixelsWide, py < picture.pixelsHigh else { return nil }
            return picture.colorAt(x: px, y: py)?.usingColorSpace(.sRGB)
        }
    }

    override func steps() -> [any Step] {
        let other = UUID().uuidString.lowercased()
        let this: @MainActor (StoryContext) throws -> String = { story in
            guard let id = try story.activeChat().listedId else { throw StoryFailure.modelMissing("the chat's session") }
            return id
        }
        return super.steps() + [
            Send("hello"), TurnFinished(1),
            Do("History lists this chat and another") { story in
                let chat = try story.activeChat()
                guard let session = chat.listedId else { throw StoryFailure.modelMissing("the chat's session") }
                ScriptedWorld.shared.list(session, provider: chat.provider.id, folder: chat.folder, title: "hello")
                ScriptedWorld.shared.list(other, provider: chat.provider.id, folder: chat.folder, title: "another")
            },
            Press(.id(StoryID.Titlebar.history)),
            ExpectElement(.id(StoryID.History.row(other)), .exists),
            Expect("this chat's row reads as current") { story in
                StoryElement(StoryID.History.row(try this(story)).part(.selected)) != nil
            },
            ExpectElement(.id(StoryID.History.row(other).part(.selected)), .absent),
            Fill(what: "this chat's row", session: this, raised: true, ground: { _ in other }),
            Snapshot("history-current"),
            // The pointer over the other row: it takes the tint, the current row stays raised.
            Press(.id(StoryID.History.row(other).part(.hover))),
            ExpectElement(.id(StoryID.History.row(other).part(.lit)), .exists),
            Fill(what: "the other row", session: { _ in other }, raised: false),
            Expect("this chat's row still current") { story in
                StoryElement(StoryID.History.row(try this(story)).part(.selected)) != nil
            },
            Fill(what: "this chat's row", session: this, raised: true, ground: { _ in other }),
            Snapshot("history-current-hover"),
            Key(.escape),
        ]
    }
}
