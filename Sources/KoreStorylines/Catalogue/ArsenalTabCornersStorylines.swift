import AppKit
import Foundation
import KoreLink
import KoreUI
import src

/// Arsenal on a chat: its tab takes the option popups' corner marks in Arsenal's blue, its CLI
/// logo keeps its own colours; off, neither. Read off the window's picture at the tab's own frame,
/// with the tab wide (alone), then narrow (eleven tabs), in front, behind and picked with another.
final class ArsenalTabCorners: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Ready.")]) }

    /// The tab's frame where its corners were last seen: the off check reads the same place.
    @MainActor private static var lastFrame: CGRect?

    /// The first chat's tab, its corners drawn (`on`) or not, and no Arsenal blue on its logo.
    private struct Pixels: Step {
        let on: Bool
        var label: String { "the first tab \(on ? "with Arsenal's corners" : "without corners"), its logo untinted" }
        var timeout: Duration? { .seconds(10) }

        @MainActor func run(_ story: StoryContext) async throws {
            try await story.idle()
            guard let id = story.app.workspace?.tabs.first?.id else { throw StoryFailure.modelMissing("the first tab") }
            let part = StoryID.Tabs.tab(id).part(.arsenal)
            if on {
                try await ExpectElement(.id(part)).run(story)
                ArsenalTabCorners.lastFrame = StoryElement(part)?.frame
            } else {
                try await ExpectElement(.id(part), .absent).run(story)
            }
            // Before the corners were ever drawn: the tab's button, its leading part.
            guard let tab = ArsenalTabCorners.lastFrame ?? StoryElement(StoryID.Tabs.tab(id))?.frame else {
                throw StoryFailure.modelMissing("the first tab's frame")
            }
            // Read again until it settles: the tab redraws on the next pass.
            var found = ""
            do {
                try await story.until(label, timeout: .seconds(3)) {
                    guard let seen = Self.blue(at: tab, in: story) else { return false }
                    found = "\(Int(tab.width))pt tab: blue at its corners \(seen.corners), inside it \(seen.inside)"
                    let fits = on ? seen.corners.allSatisfy { $0 >= 4 } : seen.corners.allSatisfy { $0 == 0 }
                    return fits && seen.inside == 0
                }
            } catch StoryFailure.timedOut {
                throw StoryFailure.expectation(found.isEmpty ? "a picture of the window" : found)
            }
        }

        /// Pixels close to Arsenal's blue (#6AB1E7, allowing for the arms' antialiasing) at each
        /// of `tab`'s corners (its arc and the start of its arms), and inside its edges (the logo).
        @MainActor static func blue(at tab: CGRect, in story: StoryContext) -> (corners: [Int], inside: Int)? {
            guard let window = story.window, let png = snapshot(window), let picture = NSBitmapImageRep(data: png) else { return nil }
            let scale = CGFloat(picture.pixelsWide) / window.frame.width
            func count(_ rect: CGRect) -> Int {
                var n = 0
                for py in Int((window.frame.height - rect.maxY) * scale)..<Int((window.frame.height - rect.minY) * scale) {
                    for px in Int(rect.minX * scale)..<Int(rect.maxX * scale)
                    where px >= 0 && py >= 0 && px < picture.pixelsWide && py < picture.pixelsHigh {
                        guard let c = picture.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                        if c.blueComponent > 0.5 && c.blueComponent - c.redComponent > 0.2 && c.greenComponent > c.redComponent { n += 1 }
                    }
                }
                return n
            }
            let reach: CGFloat = 8
            let corners = [
                CGRect(x: tab.minX, y: tab.minY, width: reach, height: reach),
                CGRect(x: tab.maxX - reach, y: tab.minY, width: reach, height: reach),
                CGRect(x: tab.minX, y: tab.maxY - reach, width: reach, height: reach),
                CGRect(x: tab.maxX - reach, y: tab.maxY - reach, width: reach, height: reach),
            ].map(count)
            return (corners, count(tab.insetBy(dx: 4, dy: 4)))
        }
    }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/katc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let key = Key(.cmdOption("k"))
        func width(_ what: String, _ fits: @escaping (CGFloat) -> Bool) -> Expect {
            Expect("the first tab \(what)") { _ in ArsenalTabCorners.lastFrame.map { fits($0.width) } ?? false }
        }
        return super.steps() + [
            Do("a socket of this run's, the switch on") { _ in
                AgentChannel.directory = directory
                AgentGrants.stopAll()
                Arsenal.shared.setAllowed(true)
            },
        ] + (variant == .codex ? [
            Do("Codex's Full access") { story in try story.activeChat().storySetMode("fullAccess") },
            Expect("Full access") { story in try story.activeChat().mode == "fullAccess" },
        ] : []) + [
            Send("hello"), TurnFinished(1),
            Pixels(on: false),
            key,
            Expect("Arsenal on") { story in try story.activeChat().arsenal != nil },
            Pixels(on: true),
            width("wide") { $0 >= 200 },
            Snapshot("arsenal-tab-wide"),

            // Narrow: eleven tabs; the first in front, behind, and picked with another.
            OpenTabs(10),
            Click(.tab(1)),
            Pixels(on: true),
            width("narrow") { $0 <= 110 },
            Snapshot("arsenal-tab-narrow"),
            Click(.tab(2)),
            Pixels(on: true),
            Snapshot("arsenal-tab-narrow-behind"),
            Click(.tab(1), modifiers: .command),
            Expect("the first tab picked, the second in front") { story in
                guard let workspace = story.app.workspace else { return false }
                return workspace.isSelected(workspace.tabs[0]) && workspace.activeTab === workspace.tabs[1]
            },
            Pixels(on: true),
            Snapshot("arsenal-tab-narrow-picked"),
            Key(.escape),

            // The narrowest: its mark alone.
            Do("a narrow window") { story in story.window?.setContentSize(CGSize(width: 420, height: 600)) },
            Click(.tab(1)),
            Pixels(on: true),
            width("at its narrowest") { $0 <= 60 },
            Snapshot("arsenal-tab-narrowest"),

            // Off: no corners, the logo as it was.
            key,
            Expect("Arsenal off") { story in try story.activeChat().arsenal == nil },
            Pixels(on: false),
            Snapshot("arsenal-tab-off"),
            Do("the window back, the switch off") { story in
                story.window?.setContentSize(story.windowSize)
                Arsenal.shared.setAllowed(false)
            },
        ]
    }
}
