import AppKit
import src
import SwiftUI

/// Resume after a close nobody chose to make mid-work (the owner via Kore-main, 2026-11-24): the
/// window closing, Kore quitting, crashing, or the Mac restarting. Each saved chat tab notes whether
/// its chat had live work then (`Chat.hasLiveWork`, the idle rest's rule too: a turn, a card
/// waiting, sub-agents, background commands, a queued send), and how many sub-agents and commands.
/// The note is kept current as turns, agents and commands start and end (`Chat.onWorkChanged`,
/// then the window's debounced save), so a crash leaves it too; a quit keeps it as it was when the
/// quit began. Reopened, the window offers those chats once: one quiet cue in the title row,
/// Resume, and each picked chat is sent a short note, as if typed. A box's chats run on there, so a
/// box window notes none; a rested chat has no live work, so it's never offered.

/// A chat working as its window went: its sub-agents and background commands then (nil: none).
struct SavedWork: Codable, Equatable {
    var agents: Int?
    var commands: Int?
}

/// The chats a reopened window offers to carry on, picked by default.
package struct ResumeOffer: Equatable {
    package struct Item: Equatable {
        package let tab: UUID
        package var agents: Int
        package var commands: Int
        package var picked = true
    }

    package var items: [Item]

    /// "Resume with sub-agents" while a picked chat had them running.
    package var withAgents: Bool { items.contains { $0.picked && $0.agents > 0 } }
    package var picked: Int { items.filter(\.picked).count }

    package var line: String {
        items.count == 1 ? "1 chat was working when Kore closed" : "\(items.count) chats were working when Kore closed"
    }

    package var action: String { withAgents ? "Resume with sub-agents" : "Resume" }
}

extension Workspace {
    /// Kore is quitting: from the quit's start, what was working is kept as it was then, not as
    /// the CLIs end (`applicationShouldTerminate`).
    package static var ending = false

    /// The note a resumed chat is sent: the same for Claude and Codex, short (it's in every resumed chat).
    package static func resumeText(agents: Int, commands: Int) -> String {
        var text = "Kore closed while you were working. Continue where you left off."
        if agents > 0 { text += " Your sub-agents were stopped too; start them again where they were." }
        if commands > 0 { text += " Background commands stopped; rerun any you still need." }
        return text
    }

    /// What a chat's tab notes now: its live work (`Chat.hasLiveWork`), else nil.
    /// A box's chats go on there; a closed chat isn't working.
    func work(of tab: ChatTab) -> SavedWork? {
        if Self.ending {
            if workAtEnd == nil { workAtEnd = Dictionary(tabs.compactMap { tab in liveWork(of: tab).map { (tab.id, $0) } }, uniquingKeysWith: { a, _ in a }) }
            return workAtEnd?[tab.id]
        }
        return liveWork(of: tab)
    }

    private func liveWork(of tab: ChatTab) -> SavedWork? {
        guard box == nil, tab.agent == nil, let chat = tab.chat, chat.hasLiveWork else { return nil }
        let agents = chat.transcript.agentSummary.running.count
        let commands = chat.commands.summary.total
        return SavedWork(agents: agents > 0 ? agents : nil, commands: commands > 0 ? commands : nil)
    }

    /// The restored tabs whose chats were working when the window went, as the saved tabs say.
    static func resumeItems(_ restored: [ChatTab], _ saved: [Saved.Tab]) -> [ResumeOffer.Item] {
        zip(restored, saved).compactMap { tab, saved in
            guard let work = saved.working, saved.session != nil, tab.chat != nil else { return nil }
            return ResumeOffer.Item(tab: tab.id, agents: work.agents ?? 0, commands: work.commands ?? 0)
        }
    }

    /// A chat's turn, agents or commands changed: the note is saved again (a crash keeps it). One
    /// the cue offers that's going again (the user sent it something) leaves the offer.
    func workChanged(_ tab: ChatTab) {
        guard box == nil, !isClosed, !Self.ending else { return }
        if resumeOffer != nil, tab.chat?.isBusy == true { dropResume(tab.id) }
        save()
    }

    /// The offer kept true to the tabs: a closed one leaves it.
    func keepResumeTrue() {
        guard let offer = resumeOffer else { return }
        let open = Set(tabs.map(\.id))
        let items = offer.items.filter { open.contains($0.tab) }
        if items.count != offer.items.count { resumeOffer = items.isEmpty ? nil : ResumeOffer(items: items) }
    }

    private func dropResume(_ tab: UUID) {
        guard var offer = resumeOffer, offer.items.contains(where: { $0.tab == tab }) else { return }
        offer.items.removeAll { $0.tab == tab }
        resumeOffer = offer.items.isEmpty ? nil : offer
    }

    /// The list's tick on a chat.
    package func toggleResume(_ tab: UUID) {
        guard var offer = resumeOffer, let index = offer.items.firstIndex(where: { $0.tab == tab }) else { return }
        offer.items[index].picked.toggle()
        resumeOffer = offer
    }

    /// Resume: each picked chat is sent its note, as if typed (queued if it's busy); the cue goes.
    package func resumeWork() {
        guard let offer = resumeOffer else { return }
        resumeOffer = nil
        var sent = 0
        for item in offer.items where item.picked {
            guard let chat = tabs.first(where: { $0.id == item.tab })?.chat else { continue }
            if chat.sendFromLink(Self.resumeText(agents: item.agents, commands: item.commands), done: nil) { sent += 1 }
        }
        UILog.event("resume-work", ["chats": String(sent), "offered": String(offer.items.count)])
    }

    /// ×: nothing sent, and the offer never comes back (the next save notes nothing working).
    package func dismissResume() {
        guard resumeOffer != nil else { return }
        resumeOffer = nil
        UILog.event("resume-work", ["dismissed": "1"])
    }

    /// The chat a resume item names, for the list.
    func resumeTitle(_ item: ResumeOffer.Item) -> String {
        let title = tabs.first { $0.id == item.tab }?.title ?? "Chat"
        return item.agents > 0 ? "\(title) · \(item.agents == 1 ? "1 sub-agent" : "\(item.agents) sub-agents")" : title
    }
}

/// The title row's one cue after a reopen: "N chats were working when Kore closed ·
/// Resume ×". The line opens the list (a tick per chat, all at first); Resume sends; × lets it go.
struct ResumeCue: View {
    let workspace: Workspace
    @StateObject private var frame = Held(CGRect.zero)
    @StateObject private var hovered = Local(false)

    var body: some View {
        if let offer = workspace.resumeOffer {
            HStack(spacing: Space.xs) {
                Button { showList() } label: {
                    Text(offer.line).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.value = $0 }
                .storyID(StoryID.Titlebar.resume.part(.title), press: showList)
                Text("·").foregroundStyle(Theme.tertiary)
                Button(offer.action) { workspace.resumeWork() }
                    .buttonStyle(.plain)
                    .disabled(offer.picked == 0)
                    .foregroundStyle(offer.picked == 0 ? Theme.tertiary : hovered.value ? Theme.text : Theme.accent)
                    .onHover { hovered.value = $0 }
                    .fixedSize()
                    .storyID(StoryID.Titlebar.resume.part(.use), press: { workspace.resumeWork() })
                IconButton(symbol: "xmark", help: "Dismiss") { workspace.dismissResume() }
                    .storyID(StoryID.Titlebar.resume.part(.cancel), press: { workspace.dismissResume() })
            }
            .font(Chrome.label)
            .storyID(StoryID.Titlebar.resume)
        }
    }

    /// A tick per chat (all at first), then Resume: a tick keeps the list open.
    private func showList() {
        guard let window = workspace.window, let content = window.contentView, let offer = workspace.resumeOffer else { return }
        let below = CGPoint(x: frame.value.minX, y: content.bounds.height - frame.value.maxY - Space.xs)
        var items = offer.items.map { item in
            OptionItem(workspace.resumeTitle(item), checked: item.picked) {
                workspace.toggleResume(item.tab)
                DispatchQueue.main.async { showList() }
            }
        }
        items += [.rule, OptionItem(offer.action, enabled: offer.picked > 0) { workspace.resumeWork() }]
        OptionsMenu.shared.show(items, at: below, in: window, source: "resume")
    }
}

extension StoryID.Titlebar {
    /// The reopened window's Resume cue: its line (the list), Resume, and ×.
    package static let resume = StoryID(.titlebar, "resume")
}
