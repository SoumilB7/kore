import AppKit
import KoreCore
import SwiftUI

/// A file tab (look §5–§7): the path row, a notice when the disk disagrees, the editor (or
/// a renderer, or a state for files Kore doesn't edit), and the status row.
struct FileEditorView: View {
    let document: FileDocument
    let tab: ChatTab
    let workspace: Workspace
    /// The turn's changes to this file, open in the changes modal.
    @StateObject private var changes = Local<[FileChange]?>(nil)
    /// A path row segment's menu, open under it.
    @StateObject private var crumbMenu = Local<CrumbMenu.Target?>(nil)

    var body: some View {
        VStack(spacing: 0) {
            PathRow(document: document, workspace: workspace, menu: crumbMenu.value) { changes.value = $0 } openMenu: { target in
                crumbMenu.value = crumbMenu.value?.anchor == target.anchor ? nil : target
            }
            Rule()
            if let notice = document.notice {
                NoticeBar(
                    notice: notice, document: document, touch: workspace.turnTouches[document.path],
                    close: { workspace.close(tab) }
                ) {
                    Task {
                        if let change = await document.compare() { changes.value = [change] }
                    }
                }
            }
            RendererHost(document: document, workspace: workspace) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !document.rendering.showsRenderer, document.loaded, document.isText {
                Rule()
                StatusRow(document: document, workspace: workspace)
            }
        }
        .background(Theme.background)
        .coordinateSpace(name: CrumbMenu.space)
        .overlay(alignment: .topLeading) {
            if let target = crumbMenu.value {
                CrumbMenu(target: target, workspace: workspace) { crumbMenu.value = nil }
                    .id(target.anchor.minX)
                    .padding(.leading, max(Space.xs, target.anchor.minX))
                    .padding(.top, target.anchor.maxY + Space.xs)
            }
        }
        // A file opened from the menu, or another tab, closes it.
        .onChange(of: document.path) { crumbMenu.value = nil }
        .overlay {
            if let list = changes.value {
                ChangesView(changes: list, folder: workspace.folder) { changes.value = nil }
            }
        }
        .animation(Motion.fade, value: changes.value == nil)
        // An edit keeps a preview tab.
        .onChange(of: document.isDirty) { _, dirty in if dirty { workspace.keep(tab) } }
    }

    @ViewBuilder private var content: some View {
        if !document.loaded {
            Color.clear
        } else {
            switch document.file.content {
            case .text:
                CodeEditorView(
                    document: document, zoom: Zoom.shared.scale, wrap: document.wrap,
                    goToLine: { workspace.quickOpen = .line })
                .overlay(alignment: .trailing) {
                    if document.editor.find.isOpen { FindTicks(find: document.editor.find, lines: document.editor.lines) }
                }
                .onAppear {
                    document.editor.textView.setStoryID(StoryID.Editor.text(workspace.relativePath(document.path)))
                    DevFileHooks.editorShown(document)
                }
                .overlay(alignment: .topTrailing) {
                    if document.editor.find.isOpen {
                        FindBar(find: document.editor.find)
                            .padding(.top, Space.md)
                            .padding(.trailing, Size.Editor.findMargin)
                            .padding(.leading, Size.Editor.findMargin)
                    }
                }
            // Images and binary files go to their renderers; this shows only if one can't take them.
            case .image, .binary:
                FileState(
                    symbol: "doc", title: "This file is binary.", line: "Kore shows text files and images.",
                    buttons: [("Open with Default App", openDefault), ("Reveal in Finder", reveal)])
            case .tooLarge(let bytes):
                FileState(
                    symbol: "doc", title: "\(document.name) is \(Self.size(bytes)).",
                    line: "Large files open without highlighting and may be slow.",
                    buttons: [("Open Anyway", document.openAnyway), ("Reveal in Finder", reveal)])
            case .unreadable(let reason):
                FileState(symbol: "lock", title: "Kore can't read this file.", line: reason, buttons: [("Try Again", document.load)])
            case .missing:
                FileState(symbol: "doc", title: "This file is missing.", line: document.path, buttons: [("Close", { workspace.close(tab) })])
            }
        }
    }

    private func openDefault() { NSWorkspace.shared.open(document.url) }
    private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Path row

private struct PathRow: View {
    let document: FileDocument
    let workspace: Workspace
    /// The open segment menu, if any (its segment shows as pressed).
    let menu: CrumbMenu.Target?
    let showChanges: ([FileChange]) -> Void
    let openMenu: (CrumbMenu.Target) -> Void

    var body: some View {
        let relative = workspace.relativePath(document.path)
        let parts = relative.split(separator: "/").map(String.init)
        let base = String(document.path.dropLast(relative.count))
        HStack(spacing: Space.xs) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Image(systemName: "chevron.right").font(Chrome.glyphCrumb).foregroundStyle(Theme.tertiary)
                }
                let path = base + parts[0...index].joined(separator: "/")
                Crumb(
                    name: part, isFile: index == parts.count - 1, path: path, open: menu?.current == path || menu?.folder == path && menu?.current == nil,
                    openMenu: openMenu)
            }
            Spacer(minLength: Space.md)
            if let touch = workspace.turnTouches[document.path] {
                TurnMark(touch: touch) {
                    if let source = touch.sources.last {
                        let list = workspace.changes(of: document.path, in: source)
                        if !list.isEmpty { showChanges(list) }
                    }
                }
            }
            RendererToggle(document: document)
        }
        .padding(.horizontal, Size.Editor.pathInset)
        .frame(height: Size.Editor.pathRow)
    }
}

/// A path row segment: a click opens its menu (`CrumbMenu`), a folder's entries or, for the
/// file, its siblings with it marked.
private struct Crumb: View {
    let name: String
    let isFile: Bool
    let path: String
    /// Its menu is open.
    let open: Bool
    let openMenu: (CrumbMenu.Target) -> Void
    @StateObject private var hovered = Local(false)
    @StateObject private var frames = Held((local: CGRect.zero, window: CGRect.zero))

    var body: some View {
        Button {
            openMenu(CrumbMenu.Target(
                folder: isFile ? (path as NSString).deletingLastPathComponent : path, current: isFile ? path : nil,
                anchor: frames.value.local, window: frames.value.window))
        } label: {
            HStack(spacing: Space.xs) {
                if isFile { FileIconView(name: name, color: Theme.text) }
                Text(name)
                    .font(Chrome.label)
                    .foregroundStyle(isFile || hovered.value ? Theme.text : Theme.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Space.xs)
            .padding(.vertical, Space.xxs)
            .background(hovered.value || open ? Theme.Row.hover(.window) : .clear, in: RoundedRectangle(cornerRadius: Radius.chip))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .onGeometryChange(for: [CGRect].self) { [$0.frame(in: .named(CrumbMenu.space)), $0.frame(in: .global)] } action: {
            frames.value = ($0[0], $0[1])
        }
        .help(isFile ? "Files beside \(name)" : "Files in \(name)")
    }
}

/// "+12 −3 this turn" at the path row's end; opens the turn's changes to this file.
private struct TurnMark: View {
    let touch: Workspace.Touch
    let action: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                if touch.writing { BlinkingDot(size: Size.Tree.point) }
                if let index = touch.agentIndex {
                    AgentAvatar(index: index, name: touch.agentName ?? "", place: .crumb)
                }
                ChangeCounts(added: touch.added, removed: touch.removed, font: Chrome.labelDigits)
                Text("this turn").font(Chrome.label).foregroundStyle(hovered.value ? Theme.secondary : Theme.tertiary)
            }
            .padding(.horizontal, Space.xs)
            .padding(.vertical, Space.xxs)
            .background(hovered.value ? Theme.Row.hover(.window) : .clear, in: RoundedRectangle(cornerRadius: Radius.chip))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help("View changes")
    }
}

// MARK: - Notice

private struct NoticeBar: View {
    let notice: FileDocument.Notice
    let document: FileDocument
    /// The agent turn that changed this file, when one did (look §7: name who changed it).
    let touch: Workspace.Touch?
    let close: () -> Void
    let compare: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            if notice == .changed, let touch, let index = touch.agentIndex {
                // A sub-agent: its shape, as on its tab.
                AgentAvatar(index: index, name: touch.agentName ?? "", place: .crumb)
            } else {
                Circle()
                    .fill(notice == .deleted ? Theme.danger : Theme.warning)
                    .frame(width: Size.statusPoint, height: Size.statusPoint)
            }
            message.font(Chrome.label).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: Space.md)
            switch notice {
            case .deleted:
                Button("Save") { document.save() }.buttonStyle(SubtleButtonStyle())
                Button("Close", action: close).buttonStyle(SubtleButtonStyle())
            case .changed:
                Button("Compare", action: compare).buttonStyle(SubtleButtonStyle()).storyID(StoryID.Editor.Notice.compare)
                Button("Reload") { document.reloadInPlace() }.buttonStyle(SubtleButtonStyle()).storyID(StoryID.Editor.Notice.reload)
                Button("Keep Mine") { document.keepMine() }.buttonStyle(SubtleButtonStyle()).storyID(StoryID.Editor.Notice.keep)
            }
        }
        .padding(.horizontal, Size.Editor.pathInset)
        .frame(height: Size.Editor.notice)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rule() }
    }

    /// "Claude changed this file in the running turn. Your edits aren't saved." (a sub-agent's
    /// name in accent); without an agent turn, the plain disk-change line.
    private var message: Text {
        switch notice {
        case .deleted:
            return Text("This file was deleted on disk.")
        case .changed:
            guard let touch, !touch.sources.isEmpty else {
                return Text("This file changed on disk. Your edits aren't saved.")
            }
            let when = touch.sources.contains(where: \.running) ? "the running turn" : "its last turn"
            let rest = Text(" changed this file in \(when). Your edits aren't saved.")
            if let agent = touch.agentName {
                return Text(agent).foregroundColor(Theme.accent) + rest
            }
            var names: [String] = []
            for source in touch.sources where !names.contains(source.provider) { names.append(source.provider) }
            return Text(names.joined(separator: " and ")) + rest
        }
    }
}

// MARK: - States

private struct FileState: View {
    let symbol: String
    let title: String
    let line: String
    let buttons: [(String, () -> Void)]

    var body: some View {
        VStack(spacing: Space.md) {
            Image(systemName: symbol).font(Chrome.glyphState).foregroundStyle(Theme.tertiary)
            Text(title).font(Chrome.bodyMedium).foregroundStyle(Theme.text).multilineTextAlignment(.center)
            Text(line).font(Chrome.label).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            HStack(spacing: Space.md) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                    Button(button.0, action: button.1).buttonStyle(SubtleButtonStyle())
                }
            }
        }
        .frame(maxWidth: Size.Editor.stateWidth)
    }
}

// MARK: - Status row

private struct StatusRow: View {
    let document: FileDocument
    let workspace: Workspace

    var body: some View {
        HStack(spacing: Space.xl) {
            Spacer(minLength: 0)
            if document.readOnly { StatusText("Read-only") }
            let caret = document.caret
            StatusItem(
                title: "Ln \(caret.line), Col \(caret.column)" + (caret.selected > 0 ? " (\(caret.selected) selected)" : ""),
                help: "Go to Line (⌃G)"
            ) { [OptionItem("Go to Line…") { workspace.quickOpen = .line }] }
            StatusItem(title: document.indent.label, help: "Indentation") {
                [OptionItem("Indent Using Spaces: 2") { document.setIndent(.spaces(2)) },
                 OptionItem("Indent Using Spaces: 4") { document.setIndent(.spaces(4)) },
                 OptionItem("Indent Using Spaces: 8") { document.setIndent(.spaces(8)) },
                 OptionItem("Indent Using Tabs") { document.setIndent(.tabs) }, .rule,
                 OptionItem("Convert Indentation to Spaces", enabled: !document.readOnly) { document.convertIndentation(toTabs: false) },
                 OptionItem("Convert Indentation to Tabs", enabled: !document.readOnly) { document.convertIndentation(toTabs: true) }]
            }
            .storyID(StoryID.Editor.Status.indent)
            StatusText(document.encodingName)
            StatusItem(title: document.lineEnding.rawValue, help: "Line endings") {
                [OptionItem("LF", checked: document.lineEnding == .lf) { document.setLineEnding(.lf) },
                 OptionItem("CRLF", checked: document.lineEnding == .crlf) { document.setLineEnding(.crlf) }]
            }
            .storyID(StoryID.Editor.Status.lineEndings)
            StatusItem(title: document.language.name, help: "Language") {
                Language.all.map { language in
                    OptionItem(language.name, checked: document.language.id == language.id) {
                        document.language = language
                        document.editor.setLanguage(language)
                    }
                }
            }
            .storyID(StoryID.Editor.Status.language)
        }
        .padding(.horizontal, Size.Editor.statusInset)
        .frame(height: Size.Editor.statusRow)
    }
}

private struct StatusText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Chrome.captionDigits).foregroundStyle(Theme.secondary).lineLimit(1)
    }
}

private struct StatusItem: View {
    let title: String
    let help: String
    let items: () -> [OptionItem]
    @StateObject private var hovered = Local(false)

    var body: some View {
        OptionMenuButton(source: "editor-status", items: items) {
            Text(title)
                .font(Chrome.captionDigits)
                .foregroundStyle(hovered.value ? Theme.text : Theme.secondary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .padding(.horizontal, Space.xs)
        .background(hovered.value ? Theme.Row.hover(.window) : .clear, in: RoundedRectangle(cornerRadius: Radius.chip))
        .onHover { hovered.value = $0 }
        .help(help)
    }
}
