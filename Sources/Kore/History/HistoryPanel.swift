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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovered.value || isOpen ? Theme.text : Theme.secondary)
                .frame(width: size, height: size)
                .background(hovered.value || isOpen ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .help("Chats in this folder")
    }
}

/// Search, chats (newest first), rename, archive. Sizes itself to the space it's given, so it
/// fits a small window or tile. Closes on Esc or a click anywhere else, and that click still
/// does what it was aimed at. It stays mounted while closed (hidden): removing a view that
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
    @StateObject private var monitor = Local<Any?>(nil)
    @FocusState private var searchFocused: Bool

    private var matches: [SessionSummary] {
        let q = query.value.trimmingCharacters(in: .whitespaces).lowercased()
        return workspace.chats.filter { chat in
            chat.archived == showArchived.value && (q.isEmpty || chat.title.lowercased().contains(q))
        }
    }

    private var archivedCount: Int { workspace.chats.count { $0.archived } }

    var body: some View {
        VStack(spacing: 8) {
            searchBar
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(matches) { chat in
                        HistoryRow(
                            session: chat,
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
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if matches.isEmpty {
                Text(!workspace.loaded ? "Loading…" : showArchived.value ? "No archived chats" : "No chats yet")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.vertical, 12)
            }
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.value = $0 }
        .opacity(isOpen ? 1 : 0)
        .allowsHitTesting(isOpen)
        .onChange(of: isOpen, initial: true) { _, open in
            if open {
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
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)
            TextField(showArchived.value ? "Search archived…" : "Search chats…", text: $query.value)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                // Hidden, it takes no keys (and focus is left alone: clearing it resets the window's).
                .disabled(!isOpen)
                .onSubmit { if let first = matches.first { open(first) } }
            Button {
                showArchived.value.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "archivebox")
                    if archivedCount > 0 { Text("\(archivedCount)") }
                }
                .font(.system(size: 12))
                .foregroundStyle(showArchived.value ? Theme.text : Theme.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(showArchived.value ? Theme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showArchived.value ? "Show chats" : "Show archived chats")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func open(_ chat: SessionSummary) {
        close()
        if chat.archived {
            Task { await workspace.unarchive(chat) }
        } else {
            workspace.open(chat)
        }
    }

    /// Esc closes (or cancels a rename first). A click outside the panel and the clock closes
    /// the panel and is passed on, so it lands on whatever it was aimed at.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, let content = window.contentView else { return event }
        if event.type == .keyDown {
            guard event.keyCode == 53 else { return event }
            if renaming.value != nil { return event }  // the row's field cancels its rename
            close()
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
    let isRenaming: Bool
    let open: () -> Void
    let startRename: () -> Void
    /// The new name, or nil when cancelled.
    let finishRename: (String?) -> Void
    let toggleArchive: () -> Void
    @StateObject private var hovered = Local(false)
    @StateObject private var draft = Local("")
    /// Return and the focus loss that follows it both end a rename; only the first counts.
    @StateObject private var finished = Local(false)
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            if isRenaming { renameField } else { title }
            if hovered.value && !isRenaming {
                iconButton("pencil", help: "Rename", action: startRename)
                iconButton(session.archived ? "tray.and.arrow.up" : "archivebox", help: session.archived ? "Unarchive" : "Archive", action: toggleArchive)
                    .padding(.trailing, 4)
            }
        }
        .background(hovered.value || isRenaming ? Theme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: 7))
        .onHover { hovered.value = $0 }
        .contextMenu {
            Button("Open", action: open)
            Button("Rename…", action: startRename)
            Button(session.archived ? "Unarchive" : "Archive", action: toggleArchive)
        }
    }

    private var title: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                ProviderLogo(provider: session.agent == .claude ? .claude : .codex, size: 13)
                Text(session.title)
                    .font(.system(size: 13))
                    .foregroundStyle(session.archived ? Theme.secondary : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if !hovered.value {
                    Text(Self.age(of: session.updated))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                        .fixedSize()
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, hovered.value ? 4 : 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(session.title)
    }

    private var renameField: some View {
        HStack(spacing: 8) {
            ProviderLogo(provider: session.agent == .claude ? .claude : .codex, size: 13)
            TextField("Name", text: $draft.value)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($fieldFocused)
                .onSubmit { finish(draft.value) }
                .onKeyPress(.escape) {
                    finish(nil)
                    return .handled
                }
                .onChange(of: fieldFocused) { _, focused in if !focused { finish(draft.value) } }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.accent.opacity(0.6)))
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
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// "now", "5m", "3h", "2d", then the date.
    private static func age(of date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        case ..<(7 * 86400): return "\(Int(seconds / 86400))d"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}
