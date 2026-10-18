import AppKit
import KoreCore
import SwiftUI

/// The sidebar's Search (VS Code's Search view, phase 10 §3): a query with match case, whole
/// word and regex, files to include and exclude, and the results grouped by file as they
/// stream in. A click opens the file at the match (preview tab); a double click keeps it.
struct SearchView: View {
    let workspace: Workspace
    let store: SearchStore
    @FocusState private var field: FieldKey?
    @FocusState private var listFocused: Bool

    enum FieldKey { case query, include, exclude }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            fields
            summary
            results
        }
        .onAppear {
            field = .query
            // rg's PATH lookup is a one-time half second; pay it before the first search.
            Task.detached { _ = try? CLIExecutable.resolve("rg") }
        }
        .onChange(of: store.focusRequest) { field = .query }
    }

    // MARK: Fields

    private var fields: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.xs) {
                HStack(spacing: Space.xxs) {
                    TextField("Search", text: $store.text)
                        .textFieldStyle(.plain)
                        .font(Chrome.body)
                        .foregroundStyle(Theme.text)
                        .focused($field, equals: .query)
                        .onSubmit { store.rerun() }
                        .onKeyPress(.downArrow) {
                            moveSelection(1)
                            listFocused = true
                            return .handled
                        }
                        .onExitCommand {
                            // Esc in an empty field goes back to the tree.
                            if store.text.isEmpty { workspace.sidebar = .explorer }
                        }
                    SearchToggle(label: "Aa", isOn: store.caseSensitive, help: "Match Case (⌥⌘C)") { store.caseSensitive.toggle() }
                        .keyboardShortcut("c", modifiers: [.command, .option])
                    SearchToggle(label: "ab", isOn: store.wholeWord, underline: true, help: "Match Whole Word (⌥⌘W)") { store.wholeWord.toggle() }
                        .keyboardShortcut("w", modifiers: [.command, .option])
                    SearchToggle(label: ".*", isOn: store.regex, help: "Use Regular Expression (⌥⌘R)") { store.regex.toggle() }
                        .keyboardShortcut("r", modifiers: [.command, .option])
                }
                .modifier(SearchField(height: Size.searchField, failed: failed, focused: field == .query))
                // Stays lit while a filter is set, so hidden filters aren't forgotten.
                IconButton(symbol: "ellipsis", kind: .small, font: Chrome.label, isOn: store.hasFilters, help: "Toggle Search Details") {
                    store.showsDetails.toggle()
                }
            }
            if store.showsDetails {
                VStack(alignment: .leading, spacing: Space.xs) {
                    DetailField(title: "files to include", text: $store.include, focused: $field, which: .include)
                    DetailField(title: "files to exclude", text: $store.exclude, focused: $field, which: .exclude)
                }
            }
        }
        .padding(.horizontal, Layout.Explorer.headerInset)
    }

    private var failed: Bool {
        if case .failed = store.outcome { return true }
        return false
    }

    // MARK: Summary

    @ViewBuilder private var summary: some View {
        Group {
            switch store.outcome {
            case .idle:
                EmptyView()
            case .running:
                Text(store.matchCount == 0 ? "Searching…" : "Searching… \(resultsText)").foregroundStyle(Theme.secondary)
            case .failed(let message):
                Text(message).foregroundStyle(Theme.danger)
            case .capped:
                Text("10,000+ results in \(filesText) · capped").foregroundStyle(Theme.secondary)
            case .done:
                if store.results.isEmpty {
                    HStack(spacing: Space.xs) {
                        Text("No results found.").foregroundStyle(Theme.secondary)
                        if store.hasFilters {
                            Button("Clear filters") { store.clearFilters() }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                } else {
                    Text(countLine).foregroundStyle(Theme.secondary)
                }
            }
        }
        .font(Chrome.caption)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Layout.Explorer.headerInset)
    }

    private var resultsText: String { store.matchCount == 1 ? "1 result" : "\(store.matchCount) results" }
    private var filesText: String { store.fileCount == 1 ? "1 file" : "\(store.fileCount) files" }

    private var countLine: String { "\(resultsText) in \(filesText)" }

    // MARK: Results

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.results) { file in
                        SearchFileRow(file: file, store: store, focused: listFocused) {
                            listFocused = true
                            store.selection = .file(file.path)
                            store.toggle(file.path)
                        }
                        .id(SearchStore.Row.file(file.path))
                        if !store.collapsed.contains(file.path) {
                            ForEach(file.hits, id: \.line) { hit in
                                SearchHitRow(hit: hit, store: store, focused: listFocused) { double in
                                    listFocused = true
                                    store.selection = .hit(file.path, line: hit.line)
                                    open(hit, keep: double)
                                }
                                .id(SearchStore.Row.hit(file.path, line: hit.line))
                            }
                        }
                    }
                }
                .padding(.bottom, Space.md)
            }
            .focusable(interactions: .edit)
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in key(press) }
            .onChange(of: store.selection) { _, row in
                if let row { withAnimation(Motion.fade) { proxy.scrollTo(row) } }
            }
        }
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .downArrow: moveSelection(1)
        case .upArrow: moveSelection(-1)
        case .return:
            switch store.selection {
            case .file(let path): store.toggle(path)
            case .hit(let path, let line): if let hit = store.hit(path, line: line) { open(hit, keep: true) }
            case nil: return .ignored
            }
        case .leftArrow:
            if case .file(let path) = store.selection, !store.collapsed.contains(path) { store.toggle(path) }
            if case .hit(let path, _) = store.selection { store.selection = .file(path) }
        case .rightArrow:
            if case .file(let path) = store.selection, store.collapsed.contains(path) { store.toggle(path) }
        default:
            return .ignored
        }
        return .handled
    }

    private func moveSelection(_ delta: Int) {
        let rows = store.visibleRows
        guard !rows.isEmpty else { return }
        let index = store.selection.flatMap { rows.firstIndex(of: $0) } ?? (delta > 0 ? -1 : rows.count)
        let next = rows[min(max(index + delta, 0), rows.count - 1)]
        store.selection = next
        // Moving onto a hit shows it, as VS Code's preview does.
        if case .hit(let path, let line) = next, let hit = store.hit(path, line: line) { open(hit, keep: false) }
    }

    private func open(_ hit: SearchHit, keep: Bool) {
        let start = hit.textOffset + (hit.matches.first?.lowerBound ?? 0)
        let length = hit.matches.first?.count ?? 0
        workspace.openFile(
            URL(fileURLWithPath: hit.path), preview: !keep,
            select: FileDocument.Place(line: hit.line, columns: start..<(start + length)))
        if keep { workspace.activeFile?.editor.focus() }
    }
}

// MARK: - Rows

private struct SearchFileRow: View {
    let file: SearchStore.FileResult
    let store: SearchStore
    let focused: Bool
    let action: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        let open = !store.collapsed.contains(file.path)
        let selected = store.selection == .file(file.path)
        let relative = store.relative(file.path)
        let folder = (relative as NSString).deletingLastPathComponent
        HStack(spacing: 0) {
            Image(systemName: "chevron.right")
                .font(Chrome.glyphTreeChevron)
                .foregroundStyle(Theme.secondary)
                .rotationEffect(.degrees(open ? 90 : 0))
                .animation(Motion.fade, value: open)
                .frame(width: Size.Tree.chevronBox, height: Size.Tree.chevronBox)
            FileIconView(name: file.path, color: selected ? Theme.text : Theme.secondary)
            Spacer().frame(width: Size.Tree.iconGap)
            Text((file.path as NSString).lastPathComponent)
                .font(Chrome.body)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .layoutPriority(1)
            if !folder.isEmpty {
                Text(folder)
                    .font(Chrome.label)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.leading, Space.sm)
            }
            Spacer(minLength: Space.md)
            Text("\(file.matchCount)")
                .font(Chrome.captionDigits)
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.leading, Size.Tree.leading)
        .padding(.trailing, Size.Tree.trailing)
        .frame(height: Size.Tree.row)
        .background(fill(selected), in: RoundedRectangle(cornerRadius: Radius.chip))
        .padding(.horizontal, Size.Tree.rowInset)
        .contentShape(Rectangle())
        .onHover { hovered.value = $0 }
        .onTapGesture(perform: action)
        .help(relative)
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) }
            Button("Copy Path") { TreeActions.copy(file.path) }
            Button("Copy Relative Path") { TreeActions.copy(relative) }
        }
    }

    private func fill(_ selected: Bool) -> Color {
        if selected { return focused ? Theme.Tree.selectedFocused : Theme.Tree.selected }
        return hovered.value ? Theme.Tree.hover : .clear
    }
}

private struct SearchHitRow: View {
    let hit: SearchHit
    let store: SearchStore
    let focused: Bool
    let action: (_ double: Bool) -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        let selected = store.selection == .hit(hit.path, line: hit.line)
        HStack(spacing: 0) {
            Text(preview)
                .font(Chrome.label)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        // Under the file name.
        .padding(.leading, Size.Tree.leading + Size.Tree.chevronBox + Size.Tree.icon + Size.Tree.iconGap)
        .padding(.trailing, Size.Tree.trailing)
        .frame(height: Size.Tree.row)
        .background(fill(selected), in: RoundedRectangle(cornerRadius: Radius.chip))
        .padding(.horizontal, Size.Tree.rowInset)
        .contentShape(Rectangle())
        .onHover { hovered.value = $0 }
        .onTapGesture { action((NSApp.currentEvent?.clickCount ?? 1) >= 2) }
        .help("Line \(hit.line)")
    }

    /// The line from just before its first match, the matches on the find fill.
    private var preview: AttributedString {
        let text = hit.text as NSString
        // A short lead-in, so the match is in view in a narrow sidebar.
        let first = hit.matches.first?.lowerBound ?? 0
        // Indentation is dropped without a "…"; cutting into the text shows one.
        var indent = 0
        while indent < first, CharacterSet.whitespaces.contains(Unicode.Scalar(text.character(at: indent)) ?? "x") { indent += 1 }
        let start = max(indent, first - Layout.Search.leadIn)
        let leading = start > indent || hit.textOffset > 0
        var result = AttributedString(leading ? "…" : "")
        result.foregroundColor = Theme.tertiary
        var cursor = start
        for match in hit.matches where match.upperBound > start {
            let lower = max(match.lowerBound, start)
            if lower > cursor {
                var plain = AttributedString(text.substring(with: NSRange(location: cursor, length: lower - cursor)))
                plain.foregroundColor = Theme.text
                result += plain
            }
            let upper = min(match.upperBound, text.length)
            guard upper > lower else { continue }
            var found = AttributedString(text.substring(with: NSRange(location: lower, length: upper - lower)))
            found.foregroundColor = Theme.text
            found.backgroundColor = Theme.Editor.findMatch
            result += found
            cursor = upper
        }
        if cursor < text.length {
            var rest = AttributedString(text.substring(from: cursor).trimmingCharacters(in: .newlines))
            rest.foregroundColor = Theme.text
            result += rest
        }
        return result
    }

    private func fill(_ selected: Bool) -> Color {
        if selected { return focused ? Theme.Tree.selectedFocused : Theme.Tree.selected }
        return hovered.value ? Theme.Tree.hover : .clear
    }
}

// MARK: - Fields

private struct DetailField: View {
    let title: String
    @Binding var text: String
    let focused: FocusState<SearchView.FieldKey?>.Binding
    let which: SearchView.FieldKey

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title).font(Chrome.caption).foregroundStyle(Theme.tertiary)
            TextField("e.g. *.swift, Sources/**", text: $text)
                .textFieldStyle(.plain)
                .font(Chrome.label)
                .foregroundStyle(Theme.text)
                .focused(focused, equals: which)
                .modifier(SearchField(height: Size.filterField, failed: false, focused: false))
        }
    }
}

private struct SearchField: ViewModifier {
    let height: CGFloat
    let failed: Bool
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Space.sm)
            .frame(height: height)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Radius.chip))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.chip)
                    .strokeBorder(failed ? Theme.danger : (focused ? Theme.borderFocused : Theme.border), lineWidth: Stroke.hairline)
            )
    }
}

private struct SearchToggle: View {
    let label: String
    let isOn: Bool
    var underline = false
    let help: String
    let action: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Chrome.captionStrong)
                .underline(underline)
                .foregroundStyle(isOn || hovered.value ? Theme.text : Theme.secondary)
                .frame(width: Size.Editor.findToggle, height: Size.Editor.findToggle)
                .background(isOn ? Theme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: Radius.glyph))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help(help)
    }
}
