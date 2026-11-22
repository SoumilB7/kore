import AppKit
import Foundation
import KoreCore
import KoreLink
import KoreUI
import LinkProtocol
import src

/// A phone asks this Mac to copy an open chat into another window here (cap "copyVia", owner
/// 2026-11-24). A long chat: the other window's bar says it's being copied, then that it was; its
/// tab opens there behind the one shown, under its own session and no higher than Manual; the
/// source keeps its tab, chat and mode. The same ask heard again (its answer lost with the phone's
/// link) makes no second tab. One whose transcript is gone is refused in the line the phone
/// shows, which the bar says too; a window closed meanwhile and a box this Mac doesn't know are
/// refused with nothing on the bar and no tab.
final class PhoneAskedCopy: OpenEndStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    /// The asks' answers, as the phone hears them.
    @MainActor final class Asked {
        var answers: [String: String] = [:]
        /// What the other window's bar said while a copy ran (a short one is over before a step looks).
        var said: Set<String> = []
        var shown: UUID?
        var mode: String?
    }

    private static func asked(_ story: StoryContext) -> Asked { story.stash(Asked.self) { Asked() } }

    /// The phone's ask: the chat's end as its Device list names it, to window `to`.
    private func ask(_ id: String, again: Bool = false, device: String? = nil, to: @escaping @MainActor @Sendable (StoryContext) throws -> String) -> Do {
        let session = session
        return Do("The phone asks (\(id)\(again ? ", heard again" : ""))") { story in
            let tab = try TabPaste.tab(story, session: session)
            let from = CopyAsk.End(windowId: LinkCopyStory.window(try TabPaste.workspace(story)), chatId: tab.chat?.id.uuidString)
            let ask = CopyAsk(
                id: "\(id)-\(session)", again: again ? true : nil, from: from, to: .init(device: device, windowId: try to(story)), provider: "claude", title: "As the phone has it")
            let key = again ? id + " again" : id
            let asked = Self.asked(story)
            let other = try? TabPaste.windows(story).otherWorkspace()
            Task { asked.answers[key] = await LinkCopyStory.ask(ask) ?? "done" }
            Task {
                while asked.answers[key] == nil {
                    if let other { asked.said.formUnion(ChatPasteStory.bar(in: other)) }
                    try? await Task.sleep(for: .milliseconds(2))
                }
            }
        }
    }

    private func answered(_ key: String, _ line: String) -> Expect {
        Expect("the phone hears “\(line)”", timeout: .seconds(20), found: { Self.asked($0).answers[key] ?? "nothing yet" }) { Self.asked($0).answers[key] == line }
    }

    /// Rows enough that the copy takes a moment, as a long chat's does.
    private func long() -> Do {
        let (session, provider) = (session, variant.provider ?? "claude")
        return Do("The chat is long on disk") { story in
            let file = provider == "claude" ? ClaudeHistory.transcript(sessionId: session, in: story.folder) : story.outputs.appendingPathComponent("\(session).jsonl")
            let words = String(repeating: "a long answer, said at length; ", count: 16)
            let row = provider == "claude"
                ? #"{"parentUuid":"a0","isSidechain":false,"message":{"id":"m1","type":"message","role":"assistant","content":[{"type":"text","text":"\#(words)"}]},"type":"assistant","uuid":"a1","timestamp":"2026-10-20T09:00:01.000Z","cwd":"\#(story.folder.path)","sessionId":"\#(session)"}"#
                : #"{"timestamp":"2026-10-20T09:00:01.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(words)"}]}}"#
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(String(repeating: row + "\n", count: 60_000).utf8))
        }
    }

    override func steps() -> [any Step] {
        let session = session
        let source: @MainActor @Sendable (StoryContext) throws -> ChatTab = { story in try TabPaste.tab(story, session: session) }
        let other: @MainActor @Sendable (StoryContext) throws -> Workspace = { story in try TabPaste.windows(story).otherWorkspace() }
        let copy: @MainActor @Sendable (StoryContext) throws -> ChatTab? = { story in
            try other(story).tabs.first { $0.chat?.sessionId != nil && $0.chat?.sessionId != session }
        }
        let otherId: @MainActor @Sendable (StoryContext) throws -> String = { story in LinkCopyStory.window(try other(story)) }
        return opened() + [
            TabPaste.scratch(session, provider: variant.provider),
            TabPaste.note(session),
            Do("The chat in its highest mode") { story in
                let chat = try source(story).chat
                let top = chat?.provider.modes.max { $0.level < $1.level }?.id
                chat?.setMode(top ?? "", remember: false)
                Self.asked(story).mode = top
            },
            OpenOtherWindow(),
            Do("Note the tab it shows") { story in
                Self.asked(story).shown = try other(story).activeTab.id
                TabPaste.windows(story).tabs = try other(story).tabs.count
            },
            long(),
            Do("The bar shows at once") { _ in ChatPasteStory.showBarAtOnce() },
            ask("ask-1", to: otherId),
            Expect("the other window's bar says it's copying", timeout: .seconds(15), found: { story in "\(Self.asked(story).said) \(Self.asked(story).answers)" }) { story in
                let other = try other(story)
                return Self.asked(story).said.contains { $0.hasPrefix("Copying chat to \(other.folder.lastPathComponent)") }
            },
            SnapshotOf("phone-copy-bar") { story in try other(story).window },
            answered("ask-1", "done"),
            Expect("the bar says it's copied", timeout: .seconds(10), found: { story in (try? other(story)).map { "\(ChatPasteStory.bar(in: $0))" } }) { story in
                let other = try other(story)
                return ChatPasteStory.bar(in: other).contains { $0.hasPrefix("Copied chat to \(other.folder.lastPathComponent)") }
            },
            Expect("its tab there, behind the one shown", timeout: .seconds(10), found: { story in
                (try? other(story)).map { "\($0.tabs.count) tabs, front \($0.activeTab.chat?.sessionId ?? "none")" }
            }) { story in
                let other = try other(story)
                return try copy(story) != nil && other.activeTab.id == Self.asked(story).shown && other.tabs.count == TabPaste.windows(story).tabs + 1
            },
            Expect("Manual there, its own title and CLI, not the phone's words", found: { story in
                (try? copy(story))?.chat.map { "\($0.provider.id) “\($0.title)” \($0.controls.mode)" }
            }) { story in
                guard let chat = try copy(story)?.chat, let from = try source(story).chat else { return false }
                return chat.provider.id == from.provider.id && chat.title == from.title && chat.controls.mode == chat.provider.modes[0].id
            },
            Expect("the chat itself in its own mode still") { story in try source(story).chat?.controls.mode == Self.asked(story).mode },
            TabPaste.sourceKept(session),
            SnapshotOf("phone-copy-landed") { story in try other(story).window },
            // The phone's link went before it heard: it asks again by the same id.
            ask("ask-1", again: true, to: otherId),
            answered("ask-1 again", "done"),
            Expect("no second tab") { story in try other(story).tabs.count == TabPaste.windows(story).tabs + 1 },
            // Asked again of a Kore that never had it (it quit meanwhile): not run.
            ask("ask-lost", again: true, to: otherId),
            answered("ask-lost again", "Kore doesn't know if that was copied · look there before copying again"),
            // Refused: a window closed meanwhile, a box this Mac doesn't know.
            ask("ask-window") { _ in "w_gone" },
            answered("ask-window", "That window isn't open in Kore any more."),
            ask("ask-box", device: "7c1f0a55-0000-4000-8000-00000000b0c5") { _ in "w_box" },
            answered("ask-box", "That box isn't one of this Mac's"),
            // The one that went well has gone from the bar.
            Do("The bar clear") { story in ChatPasteStory.dismissBar(in: try other(story)) },
            // Its transcript gone: the line, on the bar too.
            Do("The chat's transcript gone") { story in
                for case let file as URL in FileManager.default.enumerator(at: story.outputs, includingPropertiesForKeys: nil) ?? .init() where file.lastPathComponent == "\(session).jsonl" {
                    try FileManager.default.removeItem(at: file)
                }
                try? FileManager.default.removeItem(at: ClaudeHistory.transcript(sessionId: session, in: story.folder))
            },
            ask("ask-gone", to: otherId),
            answered("ask-gone", "The chat's session isn't on this Mac"),
            Expect("the bar says why", found: { story in (try? other(story)).map { "\(ChatPasteStory.transfers(in: $0))" } }) { story in
                ChatPasteStory.transfers(in: try other(story)).contains { $0.failure == "The chat's session isn't on this Mac" }
            },
            Expect("no tab for any of them") { story in
                try other(story).tabs.count == TabPaste.windows(story).tabs + 1 && other(story).activeTab.id == Self.asked(story).shown
            },
            Do("The other window in front") { story in try other(story).window?.makeKeyAndOrderFront(nil) },
            WaitIdle(), Rest(milliseconds: 300),
            SnapshotOf("phone-copy-refused") { story in try other(story).window },
            Do("Dismissed") { story in ChatPasteStory.dismissBar(in: try other(story)) },
            TabPaste.reset(),
        ]
    }
}
