import KoreCore
import SwiftUI

enum QuickOpenMode: Equatable {
    case files
    /// ⌃G, or `:` typed first.
    case line
}

/// ⌘P (look §6): the folder's files by fuzzy name, the matched characters in the accent;
/// recently opened files when nothing is typed; `:` turns it into go to line.
struct QuickOpenView: View {
    let workspace: Workspace
    let mode: QuickOpenMode
    let maxWidth: CGFloat
    @StateObject private var query = Local("")
    @StateObject private var index = Local<[String]?>(nil)
    @StateObject private var selected = Local(0)
    @FocusState private var focused: Bool

    private struct Match: Identifiable {
        let path: String
        let positions: [Int]
        var id: String { path }
    }

    private var lineMode: Bool { mode == .line || query.value.hasPrefix(":") }

    private var root: String { workspace.filesStore().root }

    private var matches: [Match] {
        let text = query.value.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            return workspace.recentFiles.map { Match(path: workspace.relativePath($0), positions: []) }
        }
        let needle = Array(text.replacingOccurrences(of: " ", with: "").utf16)
        var scored: [(Int, Match)] = []
        for path in index.value ?? [] {
            if let result = FuzzyMatch.match(needle, in: path) {
                scored.append((result.score, Match(path: path, positions: result.positions)))
            }
        }
        scored.sort { $0.0 > $1.0 }
        return scored.prefix(50).map(\.1)
    }

    var body: some View {
        let list = lineMode ? [] : matches
        VStack(spacing: 0) {
            TextField("", text: $query.value, prompt: Text(placeholder).foregroundStyle(Theme.tertiary))
                .storyID(StoryID.QuickOpen.field)
                .textFieldStyle(.plain)
                .font(Chrome.body)
                .foregroundStyle(Theme.text)
                .focused($focused)
                .padding(.horizontal, Space.xl)
                .frame(height: Size.QuickOpen.field)
                // What the list holds now: a field can keep an older closure than its rows (a file
                // index that arrives after the last keystroke re-renders the rows only).
                .onSubmit { submit(lineMode ? [] : matches) }
                .onExitCommand { close() }
                .onKeyPress(.downArrow) {
                    selected.value = min(selected.value + 1, max(list.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selected.value = max(selected.value - 1, 0)
                    return .handled
                }
            if !lineMode {
                Rule()
                rows(list)
            }
        }
        .frame(width: min(Size.QuickOpen.width, maxWidth))
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Theme.border, lineWidth: Stroke.hairline))
        .shadow(color: Elevation.floating.color, radius: Elevation.floating.radius, y: Elevation.floating.y)  // lint:allow the one shadow (Elevation.floating)
        .onAppear {
            if mode == .line { query.value = ":" }
            focused = true
        }
        .task {
            index.value = await FileIndex.files(in: URL(fileURLWithPath: root))
        }
        .onChange(of: query.value) { selected.value = 0 }
    }

    private var placeholder: String {
        if lineMode {
            let count = workspace.activeFile?.editor.lines.count ?? 0
            return count > 0 ? "Go to line 1–\(count)" : "Open a file to go to a line"
        }
        return "Search files by name"
    }

    @ViewBuilder private func rows(_ list: [Match]) -> some View {
        if list.isEmpty {
            Text(query.value.isEmpty ? "No recently opened files" : (index.value == nil ? "Listing files…" : "No matching files"))
                .font(Chrome.label)
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.xl)
                .frame(height: Size.QuickOpen.row)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if query.value.isEmpty {
                    Text("recently opened")
                        .font(Chrome.caption)
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, Space.xl)
                        .padding(.top, Space.sm)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { offset, match in
                                QuickOpenRow(path: match.path, positions: match.positions, isSelected: offset == selected.value)
                                    .id(offset)
                                    .onTapGesture { open(match) }
                                    .storyID(StoryID.QuickOpen.row(match.path), press: { open(match) })
                            }
                        }
                        .padding(Space.xs)
                    }
                    .frame(maxHeight: Size.QuickOpen.row * CGFloat(Size.QuickOpen.visibleRows) + Space.md)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: selected.value) { _, value in proxy.scrollTo(value) }
                }
            }
        }
    }

    private func submit(_ list: [Match]) {
        if lineMode {
            let digits = query.value.drop { $0 == ":" }.trimmingCharacters(in: .whitespaces)
            if let line = Int(digits.prefix { $0.isNumber }), let editor = workspace.activeFile?.editor {
                close()
                editor.goTo(line: line)
            }
            return
        }
        guard list.indices.contains(selected.value) else { return }
        open(list[selected.value])
    }

    private func open(_ match: Match) {
        close()
        workspace.openFile(URL(fileURLWithPath: root + "/" + match.path))
        // Its editor isn't in the window yet: it takes the caret as it comes up.
        workspace.activeFile?.editor.focus()
    }

    private func close() { workspace.quickOpen = nil }
}

private struct QuickOpenRow: View {
    let path: String
    let positions: [Int]
    let isSelected: Bool
    @StateObject private var hovered = Local(false)

    var body: some View {
        let nameStart = path.utf16.count - (path as NSString).lastPathComponent.utf16.count
        HStack(spacing: Space.md) {
            FileIconView(name: (path as NSString).lastPathComponent, color: Theme.secondary)
            Text(highlighted(from: nameStart, to: path.utf16.count, base: Theme.text, strong: true))
                .font(Chrome.body)
                .lineLimit(1)
            Text(highlighted(from: 0, to: max(0, nameStart - 1), base: Theme.tertiary, strong: false))
                .font(Chrome.label)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.md)
        .frame(height: Size.QuickOpen.row)
        .background(isSelected || hovered.value ? Theme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: Radius.chip))
        .contentShape(Rectangle())
        .onHover { hovered.value = $0 }
    }

    /// The UTF-16 span of the path, with matched characters in the accent.
    private func highlighted(from start: Int, to end: Int, base: Color, strong: Bool) -> AttributedString {
        let marked = Set(positions)
        var result = AttributedString()
        var offset = 0
        for character in path {
            let width = character.utf16.count
            defer { offset += width }
            guard offset >= start, offset < end else { continue }
            var piece = AttributedString(String(character))
            if marked.contains(offset) {
                piece.foregroundColor = Theme.accent
                if strong { piece.font = Chrome.bodySemibold }
            } else {
                piece.foregroundColor = base
            }
            result += piece
        }
        return result
    }
}
