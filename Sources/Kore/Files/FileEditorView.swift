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

    var body: some View {
        VStack(spacing: 0) {
            PathRow(document: document, workspace: workspace) { changes.value = $0 }
            Rule()
            if let notice = document.notice {
                NoticeBar(notice: notice, document: document, close: { workspace.close(tab) }) {
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
    let showChanges: ([FileChange]) -> Void

    var body: some View {
        let relative = workspace.relativePath(document.path)
        let parts = relative.split(separator: "/").map(String.init)
        let base = String(document.path.dropLast(relative.count))
        HStack(spacing: Space.xs) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Image(systemName: "chevron.right").font(Chrome.glyphCrumb).foregroundStyle(Theme.tertiary)
                }
                Crumb(
                    name: part, isFile: index == parts.count - 1,
                    path: base + parts[0...index].joined(separator: "/"),
                    workspace: workspace)
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

private struct Crumb: View {
    let name: String
    let isFile: Bool
    let path: String
    let workspace: Workspace
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button {
            // Shows it in the explorer.
            workspace.explorerOpen = true
            let store = workspace.filesStore()
            Task {
                await store.reveal(path)
                if !isFile { store.expand(path) }
            }
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
            .background(hovered.value ? Theme.Tree.hover : .clear, in: RoundedRectangle(cornerRadius: Radius.chip))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help("Reveal in Explorer")
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
            .background(hovered.value ? Theme.Tree.hover : .clear, in: RoundedRectangle(cornerRadius: Radius.chip))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help("\(touch.help) · View changes")
    }
}

// MARK: - Notice

private struct NoticeBar: View {
    let notice: FileDocument.Notice
    let document: FileDocument
    let close: () -> Void
    let compare: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            Circle()
                .fill(notice == .deleted ? Theme.danger : Theme.warning)
                .frame(width: Size.statusPoint, height: Size.statusPoint)
            Text(message).font(Chrome.label).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: Space.md)
            switch notice {
            case .deleted:
                Button("Save") { document.save() }.buttonStyle(SubtleButtonStyle())
                Button("Close", action: close).buttonStyle(SubtleButtonStyle())
            case .changed:
                Button("Compare", action: compare).buttonStyle(SubtleButtonStyle())
                Button("Reload") { document.reloadInPlace() }.buttonStyle(SubtleButtonStyle())
                Button("Keep Mine") { document.keepMine() }.buttonStyle(SubtleButtonStyle())
            }
        }
        .padding(.horizontal, Size.Editor.pathInset)
        .frame(height: Size.Editor.notice)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rule() }
    }

    private var message: String {
        switch notice {
        case .deleted: "This file was deleted on disk."
        case .changed: "This file changed on disk. Your edits aren't saved."
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
            ) {
                Button("Go to Line…") { workspace.quickOpen = .line }
            }
            StatusItem(title: document.indent.label, help: "Select Indentation") {
                Button("Indent Using Spaces: 2") { document.setIndent(.spaces(2)) }
                Button("Indent Using Spaces: 4") { document.setIndent(.spaces(4)) }
                Button("Indent Using Spaces: 8") { document.setIndent(.spaces(8)) }
                Button("Indent Using Tabs") { document.setIndent(.tabs) }
            }
            StatusText(document.encodingName)
            StatusItem(title: document.lineEnding.rawValue, help: "Select End of Line Sequence") {
                Button("LF") { document.setLineEnding(.lf) }
                Button("CRLF") { document.setLineEnding(.crlf) }
            }
            StatusItem(title: document.language.name, help: "Select Language Mode") {
                ForEach(Language.all, id: \.id) { language in
                    Button(language.name) {
                        document.language = language
                        document.editor.setLanguage(language)
                    }
                }
            }
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

private struct StatusItem<Items: View>: View {
    let title: String
    let help: String
    @ViewBuilder let items: () -> Items
    @StateObject private var hovered = Local(false)

    var body: some View {
        Menu {
            items()
        } label: {
            Text(title)
                .font(Chrome.captionDigits)
                .foregroundStyle(hovered.value ? Theme.text : Theme.secondary)
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, Space.xs)
        .background(hovered.value ? Theme.Tree.hover : .clear, in: RoundedRectangle(cornerRadius: Radius.chip))
        .onHover { hovered.value = $0 }
        .help(help)
    }
}
