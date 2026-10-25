import AppKit
import SwiftUI

/// What chips and cards draw: a few words of a chat read from its drawn rows (they follow
/// `tail`, at most the transcript's draw rate), never its transcript's layout.
@MainActor
struct ChatSummary {
    let title: String
    /// "Haiku · Edit automatically".
    let caption: String
    /// The latest tool at work, the reply's last line, or the error.
    let line: String?
    /// The last reply, its end, at most `Size.Board.excerpt` long.
    let reply: String?
    let failed: String?
    let approval: Approval?

    init(_ chat: Chat) {
        let transcript = chat.transcript
        _ = transcript.tail
        title = chat.title
        caption = "\(chat.controls.modelLabel) · \(chat.controls.activeMode.label)"
        failed = transcript.lastTurnFailed
        approval = chat.approvals.pending.first
        let entries = transcript.entries
        let last = entries.last { $0.kind == .answer || $0.kind == .tool || $0.kind == .notice || $0.kind == .user }
        switch last?.kind {
        case .tool?:
            line = [last?.toolName, last?.summary ?? last?.path].compactMap { $0 }.joined(separator: " · ")
        case .answer?, .notice?:
            line = last?.text.split(whereSeparator: \.isNewline).last.map(String.init)
        default:
            line = nil
        }
        reply = entries.last { $0.kind == .answer }.map { String($0.text.suffix(Size.Board.excerpt)) }
    }

    /// A chip's one line: the pending command, the error, or the latest line.
    var chipLine: String? {
        if let approval { return [approval.title, approval.body].compactMap { $0 }.joined(separator: " · ") }
        return failed ?? line
    }
}

/// One tile: its chat at the density its size gives, or the attach picker for a slot.
struct TileView: View {
    let workspace: Workspace
    let tab: ChatTab
    let model: BoardModel
    let tile: UUID
    let size: CGSize
    /// A full tile's size from before a gutter drag: it keeps it until the release.
    let frozen: CGSize?
    /// A full tile that streams live; the others show their card until focused or hovered.
    let live: Bool
    let drag: AnyGesture<DragGesture.Value>?

    var body: some View {
        Group {
            if let chat = model.chats[tile] {
                content(chat)
                    .onChange(of: chat.status.isRunning) { was, now in
                        if was, !now { model.turnEnded(chat) }
                    }
            } else {
                SlotTile(workspace: workspace, tab: tab, model: model, tile: tile, density: Density.of(size))
            }
        }
        .overlay {
            if model.focused == tile {
                RoundedRectangle(cornerRadius: Density.of(size) == .chip ? Radius.control : Radius.panel)
                    .strokeBorder(Theme.Board.focusRing, lineWidth: Stroke.hairline)
                    .allowsHitTesting(false)
            }
        }
        .simultaneousGesture(TapGesture().onEnded { model.focus(tile) })
        .allowsWindowActivationEvents(true)
        .storyID(StoryID.Board.tile(tile), press: { model.focus(tile) })
    }

    @ViewBuilder private func content(_ chat: Chat) -> some View {
        let density = model.zoomed == tile ? .full : Density.of(size)
        let state = BoardTileState.of(chat, unseen: model.isUnseen(chat))
        Group {
            switch density {
            case .chip:
                ChipView(chat: chat, state: state, model: model, tile: tile, drag: drag)
            case .card:
                CardView(chat: chat, state: state, model: model, workspace: workspace, tab: tab, tile: tile, drag: drag)
            case .full:
                if live {
                    FullTile(chat: chat, state: state, model: model, workspace: workspace, tab: tab, tile: tile, frozen: frozen, drag: drag)
                } else {
                    CardView(chat: chat, state: state, model: model, workspace: workspace, tab: tab, tile: tile, drag: drag)
                }
            }
        }
        .storyMark(StoryID.Board.density(tile, live || density != .full ? density : .card))
        .storyMark(StoryID.Board.state(tile, state))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(chat.title), \(chat.provider.name), \(state.word), \(density.rawValue)")
    }
}

/// A tile's one cue in its mark's place: the CLI-coloured spinner, a red mark, ⚠, an accent dot
/// on the CLI's logo, or the logo alone. Waiting adds corner marks to its panel, not here.
struct TileMark: View {
    let chat: Chat
    let state: BoardTileState

    var body: some View {
        switch state {
        case .working:
            ProgressView().controlSize(.small).frame(width: Size.spinner, height: Size.spinner)
                .colorMultiply(WorkingSpinner.tint(chat.provider))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .resizable().scaledToFit()
                .foregroundStyle(Theme.danger)
                .frame(width: Size.spinner, height: Size.spinner)
        case .stuck:
            Image(systemName: "exclamationmark.triangle.fill")
                .resizable().scaledToFit()
                .foregroundStyle(Theme.warning)
                .frame(width: Size.spinner, height: Size.spinner)
        case .unseen:
            ProviderLogo(provider: chat.provider, size: Size.logoTab)
                .overlay(alignment: .topTrailing) {
                    Circle().fill(Theme.accent).frame(width: Size.dot, height: Size.dot).offset(x: Size.chipBadge.width, y: Size.chipBadge.height)
                }
        case .waiting, .idle:
            ProviderLogo(provider: chat.provider, size: Size.logoTab)
        }
    }
}

/// A chip: 30pt, one line (mark, name, the latest line). Its mark and name are its handle.
private struct ChipView: View {
    let chat: Chat
    let state: BoardTileState
    let model: BoardModel
    let tile: UUID
    let drag: AnyGesture<DragGesture.Value>?

    var body: some View {
        let summary = ChatSummary(chat)
        HStack(spacing: Space.md) {
            HStack(spacing: Space.md) {
                TileMark(chat: chat, state: state)
                Text(summary.title)
                    .font(TextStyle.bodyMedium)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(drag ?? AnyGesture(DragGesture().onChanged { _ in }))
            .simultaneousGesture(TapGesture(count: 2).onEnded { model.edit { $0.setDensity(tile, .card, in: model.size) } })
            .allowsWindowActivationEvents(true)
            if let line = summary.chipLine {
                Text(line)
                    .font(TextStyle.label)
                    .foregroundStyle(state == .failed ? Theme.danger : Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, Space.lg)
        .padding(.trailing, Space.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Board.tile, in: RoundedRectangle(cornerRadius: Radius.control))
        .cornerMarks(state == .waiting ? Theme.cornerOption : nil, radius: Radius.control)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
    }
}

/// A card or full tile's 30pt header: mark, name, model · mode, and ⋯ in space it keeps for it.
/// It's the handle that moves the tile; a double click toggles card and full.
private struct TileHeader: View {
    let chat: Chat
    let state: BoardTileState
    let model: BoardModel
    let workspace: Workspace
    let tab: ChatTab
    let tile: UUID
    let drag: AnyGesture<DragGesture.Value>?
    @StateObject private var hovered = Local(false)

    var body: some View {
        HStack(spacing: Space.md) {
            TileMark(chat: chat, state: state)
            Text(chat.title)
                .font(TextStyle.bodyMedium)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .layoutPriority(1)
            Text("\(chat.controls.modelLabel) · \(chat.controls.activeMode.label)")
                .font(TextStyle.caption)
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            BoardMenuButton(source: "board-tile", items: { BoardMenus.tile(tile, workspace: workspace, tab: tab, model: model) })
                .opacity(hovered.value || model.focused == tile ? 1 : 0)
                .storyID(StoryID.Board.tileMenu(tile), press: {
                    OptionsMenu.shared.showAtPointer(BoardMenus.tile(tile, workspace: workspace, tab: tab, model: model), in: workspace.window, source: "board-tile")
                })
        }
        .padding(.leading, Space.lg)
        .padding(.trailing, Space.sm)
        .frame(height: Size.Board.tileHeader)
        .contentShape(Rectangle())
        .onHover { hovered.value = $0 }
        .simultaneousGesture(drag ?? AnyGesture(DragGesture().onChanged { _ in }))
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                let next: Density = Density.of(model.board.solve(in: model.size).tiles[tile]?.size ?? .zero) == .full ? .card : .full
                model.edit { $0.setDensity(tile, next, in: model.size) }
            })
        .allowsWindowActivationEvents(true)
        .storyID(StoryID.Board.tileHeader(tile))
    }
}

/// A card: the header, the last reply (clipped with a soft end) or the pending approval, and a
/// one-line composer; Stop while it works.
private struct CardView: View {
    let chat: Chat
    let state: BoardTileState
    let model: BoardModel
    let workspace: Workspace
    let tab: ChatTab
    let tile: UUID
    let drag: AnyGesture<DragGesture.Value>?

    var body: some View {
        let summary = ChatSummary(chat)
        VStack(alignment: .leading, spacing: 0) {
            TileHeader(chat: chat, state: state, model: model, workspace: workspace, tab: tab, tile: tile, drag: drag)
            if let approval = summary.approval, approval.isPermission {
                CompactApproval(chat: chat, approval: approval, tile: tile)
                    .padding(.horizontal, Space.md)
                Spacer(minLength: 0)
            } else {
                Group {
                    if let failed = summary.failed {
                        Text(failed).foregroundStyle(Theme.danger)
                    } else if let reply = summary.reply ?? summary.line {
                        Text(reply).foregroundStyle(Theme.text)
                    } else {
                        Text(summary.line ?? "").foregroundStyle(Theme.secondary)
                    }
                }
                .font(TextStyle.label)
                .lineSpacing(TextStyle.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.horizontal, Space.xl)
                .clipped()
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: Space.lg)
                        Rectangle()
                    }
                }
            }
            MiniComposer(chat: chat, tile: tile, model: model)
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Board.tile, in: RoundedRectangle(cornerRadius: Radius.panel))
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel))
    }
}

/// A permission at card size: what it runs, Deny and Allow, with the corner marks that say it
/// needs a choice. Answering here answers the chat: every view of it clears.
private struct CompactApproval: View {
    let chat: Chat
    let approval: Approval
    let tile: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(approval.title)
                .font(TextStyle.labelStrong)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if let body = approval.body ?? approval.detail {
                Text(body)
                    .font(TextStyle.code)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.chip))
            }
            HStack(spacing: Space.sm) {
                Spacer(minLength: 0)
                Button("Deny") { chat.answer(approval, .deny) }
                    .smallButton()
                    .storyID(StoryID.Board.tile(tile).part(.deny), press: { chat.answer(approval, .deny) })
                Button("Allow") { chat.answer(approval, .allow) }
                    .smallButton(prominent: true)
                    .storyID(StoryID.Board.tile(tile).part(.allow), press: { chat.answer(approval, .allow) })
            }
        }
        .padding(Inset.row)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Radius.panel))
        .cornerMarks(Theme.cornerOption)
    }
}

/// A card's composer: one line of the chat's own draft (the full composer and the strip tab
/// show the same), ↩ sends; Stop while a turn runs. Its outline takes the mode's colour.
private struct MiniComposer: View {
    let chat: Chat
    let tile: UUID
    let model: BoardModel

    var body: some View {
        HStack(spacing: Space.sm) {
            TextField("Message", text: Binding(get: { chat.draft }, set: { chat.draft = $0 }))
                .textFieldStyle(.plain)
                .font(TextStyle.label)
                .onSubmit(send)
                .storyID(StoryID.Board.tile(tile).part(.field))
            if chat.status.isRunning {
                Button { chat.stop() } label: {
                    Image(systemName: "stop.fill").font(Glyph.send).foregroundStyle(Theme.background)
                        .frame(width: Size.smallButton, height: Size.smallButton)
                        .background(Theme.text, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Stop")
                .storyID(StoryID.Board.tile(tile).part(.stop), press: { chat.stop() })
            }
        }
        .padding(.leading, Space.lg)
        .padding(.trailing, Space.xs)
        .frame(height: Size.Board.chip)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.control)
                .strokeBorder(chat.controls.tint ?? Theme.border, lineWidth: Stroke.hairline)
        }
    }

    private func send() {
        model.focus(tile)
        guard !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let chat = chat
        Task {
            await chat.startOnce()
            chat.send()
        }
    }
}

/// The full chat in a tile: the real transcript, approval cards and composer under the tile's
/// header, at the column a window this wide would get. During a gutter drag it keeps its size
/// from before (top-anchored, clipped) and lays out once on the release.
private struct FullTile: View {
    let chat: Chat
    let state: BoardTileState
    let model: BoardModel
    let workspace: Workspace
    let tab: ChatTab
    let tile: UUID
    let frozen: CGSize?
    let drag: AnyGesture<DragGesture.Value>?
    @FocusState private var composerFocused: Bool
    @StateObject private var actions = Held<TranscriptActions?>(nil)

    var body: some View {
        GeometryReader { proxy in
            let size = frozen ?? proxy.size
            VStack(spacing: 0) {
                TileHeader(chat: chat, state: state, model: model, workspace: workspace, tab: tab, tile: tile, drag: drag)
                TranscriptTimeline(store: chat.transcript, actions: transcriptActions).equatable()
                    .environment(\.spinnerTint, chat.controls.tint)
                VStack(spacing: Space.lg) {
                    ApprovalsView(chat: chat, maxHeight: size.height / 2)
                    ComposerView(chat: chat, workspace: workspace, focused: $composerFocused) { _ in }
                }
                .padding(.horizontal, ChatColumn.fitting(size.width).composerPadding)
                .padding(.bottom, Space.xl)
                .frame(maxWidth: ChatColumn.fitting(size.width).composerMaxWidth)
            }
            .environment(\.chatColumn, .fitting(size.width))
            .frame(width: size.width, height: size.height, alignment: .top)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Radius.panel))
        .overlay { RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Theme.border, lineWidth: Stroke.hairline) }
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel))
        .task(id: chat.id) { await chat.startOnce() }
        .onChange(of: model.focused == tile, initial: true) { _, focused in
            if focused { composerFocused = true }
        }
        .onChange(of: composerFocused) { _, focused in
            if focused, model.focused != tile { model.focus(tile) }
        }
    }

    private var transcriptActions: TranscriptActions {
        if let made = actions.value { return made }
        let made = TranscriptActions.board(chat, workspace: workspace)
        actions.value = made
        return made
    }
}

/// A slot, or an empty section's body: the attach picker in place. New Claude or Codex, then
/// this window's chats in the strip, most recent first.
struct SlotView: View {
    let workspace: Workspace
    let tab: ChatTab
    let model: BoardModel
    /// An empty section's body…
    let section: UUID?
    /// …or a slot tile.
    let slot: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                ForEach(Provider.allCases) { provider in
                    Button {
                        workspace.startChat(provider, on: tab, section: section, slot: slot)
                    } label: {
                        HStack(spacing: Space.sm) {
                            ProviderLogo(provider: provider, size: Size.logoRow)
                            Text(provider.name).font(TextStyle.label).foregroundStyle(Theme.text)
                        }
                        .padding(Inset.row)
                        .background(Theme.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.control))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .storyID(StoryID.Board.slotProvider(slot ?? section ?? tab.id, provider.id))
                }
            }
            ForEach(workspace.stripChats.prefix(6), id: \.id) { other in
                Button {
                    workspace.attach(other, to: tab, section: section, slot: slot)
                } label: {
                    HStack(spacing: Space.md) {
                        if let chat = other.chat { ProviderLogo(provider: chat.provider, size: Size.logoRow) }
                        Text(other.title).font(TextStyle.label).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(Inset.row)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .storyID(StoryID.Board.slotChat(slot ?? section ?? tab.id, other.id))
            }
            Spacer(minLength: 0)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}

/// A slot tile: full size, the picker inline; smaller, a dashed outline and a ＋ that opens it
/// as a Kore popup. Hovered, the ＋ lifts and × (closes it, its room back to its neighbours)
/// shows; neither changes size.
struct SlotTile: View {
    let workspace: Workspace
    let tab: ChatTab
    let model: BoardModel
    let tile: UUID
    let density: Density
    @StateObject private var hovered = Local(false)

    var body: some View {
        let radius = density == .chip ? Radius.control : Radius.panel
        ZStack(alignment: density == .chip ? .trailing : .topTrailing) {
            if density == .full {
                SlotView(workspace: workspace, tab: tab, model: model, section: nil, slot: tile)
                    .background(Theme.Board.tile, in: RoundedRectangle(cornerRadius: radius))
            } else {
                BoardMenuButton(source: "board-slot", symbol: "plus", lit: hovered.value, items: { BoardMenus.slot(tile, workspace: workspace, tab: tab) })
                    .storyID(StoryID.Board.slotAdd(tile), press: {
                        OptionsMenu.shared.showAtPointer(BoardMenus.slot(tile, workspace: workspace, tab: tab), in: workspace.window, source: "board-slot")
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button {
                model.edit { $0.closeSlot(tile) }
            } label: {
                Image(systemName: "xmark")
                    .font(Chrome.caption)
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: Size.Board.slotButton, height: Size.Board.slotButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, Space.xs)
            .opacity(hovered.value ? 1 : 0)
            .storyID(StoryID.Board.slotClose(tile), press: { model.edit { $0.closeSlot(tile) } })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(hovered.value ? Theme.Board.slotLineHover : Theme.Board.slotLine, style: StrokeStyle(lineWidth: Stroke.hairline, dash: Size.Board.slotDash))
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onHover { hovered.value = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Empty slot")
    }
}

/// A section: its header (swatch, name, count, and ＋ / ⋯ in room it keeps for them) over its
/// body, where its tiles are drawn by the board; an empty one shows the picker there.
struct SectionView: View {
    let workspace: Workspace
    let tab: ChatTab
    let model: BoardModel
    let section: BoardSection
    let drag: AnyGesture<DragGesture.Value>
    @StateObject private var hovered = Local(false)
    @StateObject private var name = Local("")
    @FocusState private var naming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if section.body == nil {
                SlotView(workspace: workspace, tab: tab, model: model, section: section.id, slot: nil)
                    .background(Theme.Board.tile, in: RoundedRectangle(cornerRadius: Radius.panel))
                    .padding(.horizontal, Size.Board.gap)
                    .padding(.bottom, Size.Board.gap)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Board.section)
        .onHover { hovered.value = $0 }
        .storyID(StoryID.Board.section(section.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(section.name), \(count)")
    }

    private var count: String {
        let chats = section.tiles.compactMap { model.chats[$0.id] }
        let states = chats.map { BoardTileState.of($0, unseen: false) }
        var words = ["\(chats.count)"]
        let waiting = states.filter { $0 == .waiting }.count
        let failed = states.filter { $0 == .failed }.count
        if waiting > 0 { words.append("\(waiting) waiting") }
        if failed > 0 { words.append("\(failed) failed") }
        return words.joined(separator: " · ")
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            if let swatch = section.swatch {
                RoundedRectangle(cornerRadius: Radius.glyph)
                    .fill(Theme.Board.swatch(swatch))
                    .frame(width: Size.Board.swatch, height: Size.Board.swatch)
            }
            if model.renaming == section.id {
                TextField("Section", text: $name.value)
                    .textFieldStyle(.plain)
                    .font(Chrome.label.weight(.semibold))
                    .padding(.horizontal, Space.xs)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.chip))
                    .overlay { RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Theme.accentLine, lineWidth: Stroke.hairline) }
                    .fixedSize()
                    .focused($naming)
                    .onSubmit(commitName)
                    .onExitCommand { model.renaming = nil }
                    .onAppear {
                        name.value = section.name
                        naming = true
                    }
                    .onChange(of: naming) { _, focused in if !focused { commitName() } }
                    .storyID(StoryID.Board.sectionName(section.id))
            } else {
                Text(section.name)
                    .font(Chrome.label.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { model.renaming = section.id }
            }
            Text(count)
                .font(Chrome.captionMedium)
                .foregroundStyle(Theme.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 0)
            Group {
                BoardMenuButton(source: "board-attach", symbol: "plus", items: { BoardMenus.attach(section.id, workspace: workspace, tab: tab) })
                    .storyID(StoryID.Board.sectionAdd(section.id), press: {
                        OptionsMenu.shared.showAtPointer(BoardMenus.attach(section.id, workspace: workspace, tab: tab), in: workspace.window, source: "board-attach")
                    })
                BoardMenuButton(source: "board-section", items: { BoardMenus.section(section.id, model: model, workspace: workspace, tab: tab) })
                    .storyID(StoryID.Board.sectionMenu(section.id), press: {
                        OptionsMenu.shared.showAtPointer(BoardMenus.section(section.id, model: model, workspace: workspace, tab: tab), in: workspace.window, source: "board-section")
                    })
            }
            .opacity(hovered.value ? 1 : 0)
        }
        .padding(.leading, Space.xl)
        .padding(.trailing, Space.lg)
        .frame(height: Size.Board.header)
        .contentShape(Rectangle())
        .gesture(drag)
        .allowsWindowActivationEvents(true)
        .storyID(StoryID.Board.sectionHeader(section.id))
    }

    private func commitName() {
        guard model.renaming == section.id else { return }
        model.renaming = nil
        let name = name.value
        model.edit { $0.rename(section.id, to: name) }
    }
}

/// ⋯ or ＋ in a header: opens its Kore popup under it.
struct BoardMenuButton: View {
    let source: String
    var symbol = "ellipsis"
    /// Lifted as if hovered (a slot's ＋ while the slot is).
    var lit = false
    let items: () -> [OptionItem]
    @StateObject private var hovered = Local(false)
    @StateObject private var anchor = Held(Anchor())

    final class Anchor { weak var view: NSView? }

    var body: some View {
        Button {
            guard let view = anchor.value.view, let window = view.window else { return }
            let point = view.convert(CGPoint(x: view.bounds.minX, y: view.isFlipped ? view.bounds.maxY : view.bounds.minY), to: nil)
            OptionsMenu.shared.show(items(), at: point, in: window, source: source)
        } label: {
            Image(systemName: symbol)
                .font(Chrome.label)
                .foregroundStyle(hovered.value || lit ? Theme.text : Theme.secondary)
                .frame(width: Size.Board.headerButton, height: Size.Board.headerButton)
                .background(hovered.value || lit ? Theme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: Radius.chip))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .background(AnchorView(anchor: anchor.value))
    }

    private struct AnchorView: NSViewRepresentable {
        let anchor: Anchor
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            anchor.view = view
            return view
        }
        func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
    }
}

extension OptionsMenu {
    /// A popup where the pointer is (a storyline's press, a key), in the window.
    func showAtPointer(_ items: [OptionItem], in window: NSWindow?, source: String) {
        guard let window else { return }
        show(items, at: window.mouseLocationOutsideOfEventStream, in: window, source: source)
    }
}
