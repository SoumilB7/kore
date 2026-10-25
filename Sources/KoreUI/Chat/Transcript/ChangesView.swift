import KoreCore
import SwiftUI

/// A turn's changed files over the chat (look.md §8): a file list on the left, every file's diff
/// stacked on the right under a sticky header, and a floating bar to step through them. Esc or
/// Done closes; ↑ ↓ (or k j) change file. In a narrow tile the list becomes a menu.
struct ChangesView: View {
    let changes: [FileChange]
    var folder: URL?
    let close: () -> Void
    @StateObject private var selected = Local(0)
    @StateObject private var keyMonitor = Local<Any?>(nil)
    @StateObject private var window = Local<NSWindow?>(nil)
    /// The chat's: a file opens in a Kore tab.
    @Environment(\.openURL) private var openURL

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < Size.changesListMinWindow
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    Theme.background
                    HStack(spacing: 0) {
                        if !narrow {
                            fileList(proxy)
                                .frame(width: Size.changesList)
                            Rectangle().fill(Theme.border).frame(width: Stroke.hairline)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                if narrow { fileMenu(proxy) }
                                Spacer()
                                IconButton(symbol: "xmark", help: "Close (Esc)", action: close)
                            }
                            .padding(Layout.Viewer.closeInset)
                            diffs
                        }
                    }
                    bar(proxy).padding(.bottom, Layout.Viewer.toolbarBottom).padding(.horizontal, Space.xl)
                }
                .onChange(of: selected.value) { _, index in
                    withAnimation(Motion.fade) { proxy.scrollTo(changes[index].id, anchor: .top) }
                }
            }
        }
        .background(WindowReader { window.value = $0 })
        .transition(.opacity)
        .onAppear {
            keyMonitor.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { handleKey($0) }
        }
        .onDisappear {
            if let monitor = keyMonitor.value { NSEvent.removeMonitor(monitor) }
            keyMonitor.value = nil
        }
    }

    // MARK: Parts

    private func fileList(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(changes.enumerated()), id: \.element.id) { index, change in
                    FileListRow(change: change, folder: folder, selected: index == selected.value) {
                        selected.value = index
                    }
                    .storyID(StoryID.Changes.file(Self.relative(change.path, folder)))
                }
            }
            .padding(Space.sm)
        }
    }

    private func fileMenu(_ proxy: ScrollViewProxy) -> some View {
        OptionMenuButton(source: "changes", items: {
            changes.enumerated().map { index, change in
                OptionItem(Self.name(change.path), checked: selected.value == index) { selected.value = index }
            }
        }) {
            if changes.indices.contains(selected.value) {
                let change = changes[selected.value]
                HStack(spacing: Space.sm) {
                    Text(Self.name(change.path)).font(TextStyle.label).foregroundStyle(Theme.text).lineLimit(1)
                    ChangeCounts(added: change.added, removed: change.removed)
                }
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var diffs: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(changes) { change in
                    Section {
                        Group {
                            if case .move = change.kind, change.hunks.isEmpty {
                                Text("Moved, no edits")
                                    .font(TextStyle.label)
                                    .foregroundStyle(Theme.secondary)
                            } else {
                                DiffView(change: change, folder: folder, style: .panel, maxHeight: nil)
                            }
                        }
                        .padding(.horizontal, Layout.Viewer.canvasSide)
                        .padding(.vertical, Space.md)
                    } header: {
                        header(change)
                    }
                    .id(change.id)
                }
                Color.clear.frame(height: Layout.Viewer.canvasBottom)
            }
        }
    }

    private func header(_ change: FileChange) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.md) {
                Text(Self.relative(change.path, folder))
                    .font(TextStyle.codeSmall)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.head)
                ChangeCounts(added: change.added, removed: change.removed)
                Spacer(minLength: Space.md)
                IconButton(symbol: "arrow.up.forward.app", kind: .small, help: "Open in editor") {
                    openURL(OpenInEditor.url(change.path, in: folder))
                }
            }
            .padding(.horizontal, Layout.Viewer.canvasSide)
            .padding(.vertical, Space.xs)
            Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
        }
        .background(Theme.background)
    }

    private func bar(_ proxy: ScrollViewProxy) -> some View {
        FloatingBar {
            HStack(spacing: Space.sm) {
                Text(changes.count == 1 ? "1 file" : "\(changes.count) files")
                    .font(TextStyle.label)
                    .foregroundStyle(Theme.secondary)
                Text("·").font(TextStyle.label).foregroundStyle(Theme.tertiary)
                ChangeCounts(added: changes.reduce(0) { $0 + $1.added }, removed: changes.reduce(0) { $0 + $1.removed })
            }
            .padding(.horizontal, Space.sm)
            BarDivider()
            IconButton(symbol: "chevron.up", help: "Previous file (↑)", action: previous)
                .disabled(selected.value == 0)
            IconButton(symbol: "chevron.down", help: "Next file (↓)", action: next)
                .disabled(selected.value >= changes.count - 1)
            BarDivider()
            Button("Done", action: close).storyID(StoryID.Changes.done)
                .buttonStyle(SubtleButtonStyle(prominent: true))
        }
    }

    // MARK: Keys

    private func previous() { selected.value = max(0, selected.value - 1) }
    private func next() { selected.value = min(changes.count - 1, selected.value + 1) }

    /// While open the modal has this window's keys: Esc and Return close, ↑ ↓ / k j change
    /// file. Other plain keys are swallowed; ⌘ shortcuts (zoom, ⌘W) pass through.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let window = window.value, event.window === window else { return event }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) { return event }
        switch event.keyCode {
        case 53, 36, 76: close()
        case 126: previous()
        case 125: next()
        default:
            switch event.charactersIgnoringModifiers {
            case "k": previous()
            case "j": next()
            default: break
            }
        }
        return nil
    }

    static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    static func relative(_ path: String, _ folder: URL?) -> String {
        guard let root = folder?.standardizedFileURL.path, path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }
}

/// One file in the modal's list: kind glyph, name, folder, counts.
private struct FileListRow: View {
    let change: FileChange
    let folder: URL?
    let selected: Bool
    let select: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: select) {
            HStack(spacing: Space.md) {
                Image(systemName: glyph)
                    .font(Glyph.rowIcon)
                    .foregroundStyle(Theme.secondary)
                    .frame(width: Size.disclosure)
                VStack(alignment: .leading, spacing: 0) {
                    Text(ChangesView.name(change.path))
                        .font(TextStyle.label)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if !directory.isEmpty {
                        Text(directory)
                            .font(TextStyle.caption)
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: Space.sm)
                ChangeCounts(added: change.added, removed: change.removed)
            }
            .padding(Inset.row)
            .hoverFill(selected || hovered.value, selected ? Theme.Row.selected(.window) : Theme.Row.hover(.window))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help(change.path)
    }

    private var directory: String {
        let relative = ChangesView.relative(change.path, folder)
        let dir = (relative as NSString).deletingLastPathComponent
        return dir == "." ? "" : dir
    }

    private var glyph: String {
        switch change.kind {
        case .add: "plus"
        case .update: "pencil"
        case .delete: "minus"
        case .move: "arrow.right"
        }
    }
}
