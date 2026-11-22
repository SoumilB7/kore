import AppKit
import Foundation
import KoreLink
import KoreUI
import src

/// Arsenal on a chat: its tab's CLI logo turns Arsenal's blue, and nothing else of the tab does
/// (no corner marks); off, the logo keeps its own colours. Read off the window's picture at the
/// tab's own frame. History's rows the same: the open chat's, a closed one's kept tier
/// (`ArsenalMemory`), and none for a chat without it.
final class ArsenalLogoTint: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Ready.")]) }

    /// The first chat's tab logo in Arsenal's blue (`on`) and no blue elsewhere on the tab, or no
    /// blue on the tab at all.
    private struct Pixels: Step {
        let on: Bool
        var label: String { "the first tab's logo \(on ? "in Arsenal's blue, nothing else" : "in its own colours")" }
        var timeout: Duration? { .seconds(10) }

        @MainActor func run(_ story: StoryContext) async throws {
            try await story.idle()
            guard let id = story.app.workspace?.tabs.first?.id else { throw StoryFailure.modelMissing("the first tab") }
            let part = StoryID.Tabs.tab(id).part(.arsenal)
            try await ExpectElement(.id(part), on ? .exists : .absent).run(story)
            guard let tab = StoryElement(StoryID.Tabs.tab(id))?.frame else { throw StoryFailure.modelMissing("the first tab's frame") }
            let logo = on ? StoryElement(part)?.frame : nil
            // Read again until it settles: the tab redraws on the next pass.
            var found = ""
            do {
                try await story.until(label, timeout: .seconds(3)) {
                    guard let all = Self.blue(in: tab, story) else { return false }
                    let onLogo = logo.flatMap { Self.blue(in: $0, story) } ?? 0
                    found = "\(Int(tab.width))pt tab: \(onLogo) blue on its logo, \(all - onLogo) elsewhere"
                    return (on ? onLogo >= 8 : true) && all - onLogo == 0
                }
            } catch StoryFailure.timedOut {
                throw StoryFailure.expectation(found.isEmpty ? "a picture of the window" : found)
            }
        }

        /// Pixels close to Arsenal's blue (#6AB1E7, allowing for antialiasing) in `rect`.
        @MainActor static func blue(in rect: CGRect, _ story: StoryContext) -> Int? {
            guard let window = story.window, let png = snapshot(window), let picture = NSBitmapImageRep(data: png) else { return nil }
            let scale = CGFloat(picture.pixelsWide) / window.frame.width
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
    }

    /// A History row's logo in Arsenal's blue (`on`), or without its `.arsenal` mark.
    private struct HistoryLogo: Step {
        let what: String
        let session: @MainActor (StoryContext) throws -> String
        let on: Bool
        var label: String { "History: \(what)'s logo \(on ? "in Arsenal's blue" : "in its own colours")" }
        var timeout: Duration? { .seconds(10) }

        @MainActor func run(_ story: StoryContext) async throws {
            let part = StoryID.History.row(try session(story)).part(.arsenal)
            try await ExpectElement(.id(StoryID.History.row(try session(story))), .exists).run(story)
            try await ExpectElement(.id(part), on ? .exists : .absent).run(story)
            guard on else { return }
            var found = 0
            do {
                try await story.until(label, timeout: .seconds(3)) {
                    guard let logo = StoryElement(part)?.frame, let blue = Pixels.blue(in: logo, story) else { return false }
                    found = blue
                    return blue >= 8
                }
            } catch StoryFailure.timedOut {
                throw StoryFailure.expectation("\(found) blue on \(what)'s logo")
            }
        }
    }

    override func steps() -> [any Step] {
        let kept = UUID().uuidString.lowercased()
        let off = UUID().uuidString.lowercased()
        let directory = URL(fileURLWithPath: "/tmp/kalt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let key = Key(.cmdOption("k"))
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
            Snapshot("arsenal-tab-tint"),
            Do("History lists this chat, a closed one kept at Watch, one without Arsenal") { story in
                let chat = try story.activeChat()
                guard let session = chat.listedId else { throw StoryFailure.modelMissing("the chat's session") }
                ScriptedWorld.shared.list(session, provider: chat.provider.id, folder: chat.folder, title: "hello")
                ScriptedWorld.shared.list(kept, provider: chat.provider.id, folder: chat.folder, title: "kept")
                ScriptedWorld.shared.list(off, provider: chat.provider.id, folder: chat.folder, title: "off")
                ArsenalMemory.keep(.watch, under: ArsenalMemory.key(cli: chat.provider.id, session: kept))
            },
            Press(.id(StoryID.Titlebar.history)),
            HistoryLogo(what: "this chat", session: { story in try story.activeChat().listedId ?? "" }, on: true),
            HistoryLogo(what: "the kept chat", session: { _ in kept }, on: true),
            HistoryLogo(what: "the chat without Arsenal", session: { _ in off }, on: false),
            Snapshot("arsenal-history-tint"),
            Key(.escape),
            Do("the kept chat forgotten") { story in
                ArsenalMemory.keep(nil, under: ArsenalMemory.key(cli: try story.activeChat().provider.id, session: kept))
            },
            key,
            Expect("Arsenal off") { story in try story.activeChat().arsenal == nil },
            Pixels(on: false),
            Snapshot("arsenal-tab-off"),
            Do("the switch off") { _ in Arsenal.shared.setAllowed(false) },
        ]
    }
}
