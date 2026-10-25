import AppKit
import KoreCore
import SwiftUI

/// The clock in the title row. It opens the history panel, which is drawn inside the window
/// (see FolderWindow), not as a popover: a popover can hang outside the window, and the click
/// that closes it is swallowed instead of reaching what was clicked.
struct HistoryButton: View {
    @Binding var isOpen: Bool
    /// Where the clock is, so a click on it isn't also taken as "click outside the panel".
    @Binding var frame: CGRect
    let size: CGFloat
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            Image(systemName: "clock")
                .font(Chrome.bodyMedium)
                .foregroundStyle(hovered.value || isOpen ? Theme.text : Theme.secondary)
                .frame(width: size, height: size)
                .background(hovered.value || isOpen ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .help("History")
    }
}

/// Search, chats (newest first), rename, archive. Sizes itself to the space it's given, so it
/// fits a small window or tile. ↑ ↓ move the lit row and Return opens it. Closes on Esc or a
/// click anywhere else, and that click still does what it was aimed at. It stays mounted while closed (hidden): removing a view that
/// holds focus makes SwiftUI reset the window's focus, which undid the click's focus.
struct HistoryPanel: View {
    let workspace: Workspace
    let isOpen: Bool
    let anchor: CGRect
    let close: () -> Void
    @StateObject private var query = Local("")
    @StateObject private var showArchived = Local(false)
    @StateObject private var renaming = Local<String?>(nil)
    @StateObject private var frame = Local(CGRect.zero)
    /// The list's height as its rows make it: the panel hugs a short list and scrolls a long one.
    @StateObject private var listHeight = Local<CGFloat>(0)
    @StateObject private var monitor = Local<Any?>(nil)
    /// The one lit row, by its place in `matches`: the pointer's or the keys'. Nil until either
    /// moves it, when the first row is lit and Return opens it.
    @StateObject private var lit = Local<Int?>(nil)
    @StateObject private var window = Held<NSWindow?>(nil)
    @FocusState private var searchFocused: Bool

    private var matches: [SessionSummary] {
        let q = query.value.trimmingCharacters(in: .whitespaces).lowercased()
        return workspace.chats.filter { chat in
            chat.archived == showArchived.value && (q.isEmpty || chat.title.lowercased().contains(q))
        }
    }

    private var archivedCount: Int { workspace.chats.count { $0.archived } }

    var body: some View {
        let matches = matches
        return VStack(spacing: Space.md) {
            searchBar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Space.xxs) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, chat in
                            HistoryRow(
                                session: chat,
                                lit: (lit.value ?? 0) == index,
                                showsActions: lit.value == index,
                                isRenaming: renaming.value == chat.id,
                                open: { open(chat) },
                                startRename: { renaming.value = chat.id },
                                finishRename: { name in
                                    renaming.value = nil
                                    if let name, name != chat.title { Task { await workspace.rename(chat, to: name) } }
                                },
                                toggleArchive: {
                                    Task { chat.archived ? await workspace.unarchive(chat) : await workspace.archive(chat) }
                                })
                            .highlightRow(StoryID.History.row(chat.id), lit: (lit.value ?? 0) == index) { lit.value = index }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight.value = $0 }
                }
                .onChange(of: lit.value) { _, index in
                    if let index, matches.indices.contains(index) { proxy.scrollTo(matches[index].id) }
                }
            }
            // Up to the room the window gives it, never its whole height laid out at once (a big
            // folder's hundreds of rows made the panel overflow the window, laggy and unscrollable).
            .frame(maxHeight: max(listHeight.value, 1))

            if matches.isEmpty {
                Text(!workspace.loaded ? "Loading…" : showArchived.value ? "No archived chats" : "No chats yet")
                    .font(Chrome.label)
                    .foregroundStyle(Theme.tertiary)
                    .padding(.vertical, Space.xl)
            }
        }
        .padding(Space.lg)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption, shown: isOpen)
        .shadow(color: Elevation.floating.color, radius: Elevation.floating.radius, y: Elevation.floating.y)  // lint:allow the one shadow (Elevation.floating)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.value = $0 }
        .background(WindowReader { window.value = $0 })
        .opacity(isOpen ? 1 : 0)
        .allowsHitTesting(isOpen)
        .onChange(of: query.value) { lit.value = nil }
        .onChange(of: showArchived.value) { lit.value = nil }
        .onChange(of: isOpen, initial: true) { _, open in
            lit.value = nil
            if open {
                PointerGate.keyed()
                searchFocused = true
                monitor.value = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
                    handle(event)
                }
                Task { await workspace.refresh() }
            } else {
                if let m = monitor.value { NSEvent.removeMonitor(m) }
                monitor.value = nil
                renaming.value = nil
            }
        }
        .onDisappear {
            if let m = monitor.value { NSEvent.removeMonitor(m) }
            monitor.value = nil
        }
    }

    private var searchBar: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "magnifyingglass")
                .font(Chrome.label)
                .foregroundStyle(Theme.tertiary)
            TextField(showArchived.value ? "Search archived…" : "Search chats…", text: $query.value)
                .textFieldStyle(.plain)
                .storyID(StoryID.History.search)
                .font(Chrome.body)
                .focused($searchFocused)
                // Hidden, it takes no keys (and focus is left alone: clearing it resets the window's).
                .disabled(!isOpen)
                .onSubmit(openLit)
            Button {
                showArchived.value.toggle()
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "archivebox")
                    if archivedCount > 0 { Text("\(archivedCount)") }
                }
                .font(Chrome.label)
                .foregroundStyle(showArchived.value ? Theme.text : Theme.tertiary)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xs)
                .hoverFill(showArchived.value)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showArchived.value ? "Show chats" : "Show archived chats")
        }
        .padding(Inset.search)
        .panel(.well)
    }

    /// Return: the lit row, the first until the pointer or the keys move.
    private func openLit() {
        let list = matches
        if list.indices.contains(lit.value ?? 0) { open(list[lit.value ?? 0]) }
    }

    /// ↑ ↓ from the lit row, stopping at the ends; from none, the first row is lit already.
    private func move(_ step: Int) {
        let count = matches.count
        guard count > 0 else { return }
        lit.value = min(max((lit.value ?? 0) + step, 0), count - 1)
        PointerGate.keyed()
    }

    private func open(_ chat: SessionSummary) {
        close()
        if chat.archived {
            Task { await workspace.unarchive(chat) }
        } else {
            workspace.open(chat)
        }
    }

    /// Esc closes (or cancels a rename first); ↑ ↓ and Return go to the list, whatever has
    /// focus in the panel. A click outside the panel and the clock closes the panel and is passed
    /// on, so it lands on whatever it was aimed at.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, let content = window.contentView else { return event }
        if event.type == .keyDown {
            // The row's field has the keys during a rename: it cancels on Esc.
            guard renaming.value == nil, window === self.window.value,
                event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            else { return event }
            switch event.keyCode {
            case 53: close()
            case 125: move(1)
            case 126: move(-1)
            case 36, 76: openLit()
            default: return event
            }
            return nil
        }
        let location = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        if !frame.value.contains(location) && !anchor.contains(location) {
            // Let go of the search field now, before the click is handled: if SwiftUI still
            // thinks it's focused when the panel hides, it resets the window's focus and undoes
            // whatever focus the click gave.
            window.makeFirstResponder(nil)
            close()
        }
        return event
    }
}

private struct HistoryRow: View {
    let session: SessionSummary
    /// The panel's one highlight: the pointer's row, or the keys'.
    let lit: Bool
    /// Rename and Archive: on the row the pointer or the keys moved to.
    let showsActions: Bool
    let isRenaming: Bool
    let open: () -> Void
    let startRename: () -> Void
    /// The new name, or nil when cancelled.
    let finishRename: (String?) -> Void
    let toggleArchive: () -> Void
    @StateObject private var draft = Local("")
    /// Return and the focus loss that follows it both end a rename; only the first counts.
    @StateObject private var finished = Local(false)
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            if isRenaming { renameField } else { title.storyID(StoryID.History.row(session.id)) }
            if showsActions && !isRenaming {
                iconButton("pencil", help: "Rename", action: startRename)
                iconButton(session.archived ? "tray.and.arrow.up" : "archivebox", help: session.archived ? "Unarchive" : "Archive", action: toggleArchive)
                    .storyID(StoryID.History.row(session.id).part(.archive))
                    .padding(.trailing, Space.xs)
            }
        }
        // Archive is built only on hover: pressed through its action meanwhile.
        .storyAction(StoryID.History.row(session.id).part(.archive)) { toggleArchive() }
        .hoverFill(lit || isRenaming, Theme.Row.selected(.surface))
        .contextMenu {
            Button("Open", action: open)
            Button("Rename…", action: startRename)
            Button(session.archived ? "Unarchive" : "Archive", action: toggleArchive)
        }
        // Built only on the lit row: VoiceOver and the keyboard reach them on any row.
        .accessibilityAction(named: "Rename", startRename)
        .accessibilityAction(named: session.archived ? "Unarchive" : "Archive", toggleArchive)
    }

    private var title: some View {
        Button(action: open) {
            HStack(spacing: Space.md) {
                ProviderLogo(provider: Registry.provider(for: session.agent), size: Size.logoRow)
                Text(session.title)
                    .font(Chrome.body)
                    .foregroundStyle(session.archived ? Theme.secondary : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // A chat Kore made by an import names where it came from.
                if let source = HandoffRecords.record(target: session.id)?.sourceProduct {
                    Text("from \(source)").font(Chrome.label).foregroundStyle(Theme.tertiary).fixedSize()
                }
                Spacer(minLength: Space.md)
                if !showsActions {
                    Text(session.updated.historyAge)
                        .font(Chrome.label)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize()
                }
            }
            .padding(.leading, Space.lg)
            .padding(.trailing, showsActions ? 4 : 10)
            .padding(.vertical, Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(session.title)
    }

    private var renameField: some View {
        HStack(spacing: Space.md) {
            ProviderLogo(provider: Registry.provider(for: session.agent), size: Size.logoRow)
            TextField("Name", text: $draft.value)
                .textFieldStyle(.plain)
                .font(Chrome.body)
                .focused($fieldFocused)
                .onSubmit { finish(draft.value) }
                .onKeyPress(.escape) {
                    finish(nil)
                    return .handled
                }
                .onChange(of: fieldFocused) { _, focused in if !focused { finish(draft.value) } }
        }
        .padding(Inset.row)

        .overlay(RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Theme.accentLine))
        .onAppear {
            draft.value = session.title
            finished.value = false
            fieldFocused = true
        }
    }

    private func finish(_ name: String?) {
        guard !finished.value else { return }
        finished.value = true
        finishRename(name)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Chrome.label)
                .foregroundStyle(Theme.secondary)
                .frame(width: Size.iconButtonSmall, height: Size.iconButtonSmall)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension Date {
    /// "now", "5m", "3h", "2d", then the date: a history row's age.
    var historyAge: String {
        let seconds = Date().timeIntervalSince(self)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        case ..<(7 * 86400): return "\(Int(seconds / 86400))d"
        default: return formatted(.dateTime.month(.abbreviated).day())
        }
    }
}
