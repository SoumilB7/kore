import KoreCore
import SwiftUI

/// One file's change as a unified diff (look.md §4): hunk strips, old and new line numbers, a
/// sign column, added lines on green and removed on red. Lines don't wrap; long ones scroll
/// sideways inside the panel. Inline it stops at `Size.diffInlineMax` and scrolls; in the
/// changes modal (`maxHeight` nil) it's uncapped. Rows are fixed height and built lazily.
struct DiffView: View {
    let change: FileChange
    var folder: URL?
    /// The tool body box in the timeline, `.well` in an approval card, `.panel` in the modal.
    var style = PanelStyle.toolBody
    var maxHeight: CGFloat? = Size.diffInlineMax
    /// The layout and the change it was worked out for: a body with the same change reuses it.
    @StateObject private var cached = Held<(change: FileChange, layout: DiffLayout)?>(nil)

    var body: some View {
        if change.isBinary {
            message("Binary file", open: false)
        } else if change.isTruncated || change.hunks.reduce(0, { $0 + $1.lines.count }) > Size.diffLineLimit {
            message("Diff too large to preview", open: true)
        } else if !change.hunks.isEmpty {
            diff(layout)
        }
    }

    /// Once per change. (Comparing an unchanged change is quick: its arrays share storage.)
    private var layout: DiffLayout {
        if let cached = cached.value, cached.change == change { return cached.layout }
        let layout = DiffLayout(change.hunks)
        cached.value = (change, layout)
        return layout
    }

    private func diff(_ layout: DiffLayout) -> some View {
        let rowHeight = Size.diffRow * Zoom.shared.scale
        let hunkHeight = Size.diffHunk * Zoom.shared.scale
        let height = CGFloat(layout.hunkCount) * hunkHeight + CGFloat(layout.rows.count - layout.hunkCount) * rowHeight
        return ScrollView(maxHeight == nil ? .horizontal : [.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(layout.rows) { row in
                    DiffRowView(row: row, numberWidth: layout.numberWidth, height: row.kind == .hunk ? hunkHeight : rowHeight)
                }
            }
            // Rows as wide as the widest line, or the box when that's wider: sized by layout,
            // so a resize doesn't run this body again.
            .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in max(length, layout.width) }
        }
        .scrollIndicators(.automatic)
        .frame(height: maxHeight.map { min(height, $0) } ?? height)
        .panel(style)
        .clipShape(RoundedRectangle(cornerRadius: style.radius))
    }

    private func message(_ text: String, open: Bool) -> some View {
        HStack(spacing: Space.md) {
            Text(text)
                .font(TextStyle.label)
                .foregroundStyle(Theme.secondary)
            if open { OpenInEditor(path: change.path, folder: folder) }
            Spacer(minLength: 0)
        }
        .padding(Inset.toolRow)
        .panel(style)
    }
}

/// A diff's rows and column widths, worked out once per change. Menlo is fixed-width, so the
/// widths come from character counts instead of measuring text.
@MainActor
struct DiffLayout {
    struct Row: Identifiable {
        enum Kind { case hunk, context, add, remove }
        let id: Int
        let kind: Kind
        let text: String
        let old: Int?
        let new: Int?
    }

    let rows: [Row]
    let hunkCount: Int
    /// One line-number column, padding included.
    let numberWidth: CGFloat
    /// The widest row.
    let width: CGFloat

    init(_ hunks: [FileChange.Hunk]) {
        var rows: [Row] = []
        var widest = 0, largest = 0
        for hunk in hunks {
            let oldCount = hunk.lines.count { $0.kind != .add }
            let newCount = hunk.lines.count { $0.kind != .remove }
            let header = "@@ −\(hunk.oldStart),\(oldCount) +\(hunk.newStart),\(newCount) @@"
            rows.append(Row(id: rows.count, kind: .hunk, text: header, old: nil, new: nil))
            for line in hunk.lines {
                let text = line.text.replacingOccurrences(of: "\t", with: "    ")
                widest = max(widest, text.count)
                largest = max(largest, line.old ?? 0, line.new ?? 0)
                let kind: Row.Kind = switch line.kind {
                case .context: .context
                case .add: .add
                case .remove: .remove
                }
                rows.append(Row(id: rows.count, kind: kind, text: text, old: line.old, new: line.new))
            }
        }
        self.rows = rows
        hunkCount = hunks.count
        numberWidth = CGFloat(max(3, String(largest).count)) * Mono.advance + 2 * Size.diffNumberPad
        width = 2 * numberWidth + Stroke.fine + Size.diffSign + CGFloat(widest) * Mono.advance + Size.diffNumberPad
    }
}

private struct DiffRowView: View {
    let row: DiffLayout.Row
    let numberWidth: CGFloat
    let height: CGFloat

    var body: some View {
        Group {
            if row.kind == .hunk {
                Text(row.text)
                    .foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, Size.diffNumberPad)
            } else {
                HStack(spacing: 0) {
                    number(row.old)
                    number(row.new)
                    Rectangle().fill(Theme.border).frame(width: Stroke.fine)
                    Text(sign)
                        .foregroundStyle(signColor)
                        .frame(width: Size.diffSign)
                    Text(row.text)
                        .foregroundStyle(Theme.text)
                        .fixedSize()
                }
            }
        }
        .font(TextStyle.codeSmall)
        .lineLimit(1)
        // Row by row: the whole diff at once would build every line's selection under the pointer.
        .selectableOnHover()
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .background(fill)
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .foregroundStyle(Theme.diffGutter)
            .frame(width: numberWidth - 2 * Size.diffNumberPad, alignment: .trailing)
            .padding(.horizontal, Size.diffNumberPad)
    }

    private var sign: String {
        switch row.kind {
        case .add: "+"
        case .remove: "−"
        default: ""
        }
    }

    private var signColor: Color { row.kind == .add ? Theme.diffAdd : Theme.diffRemove }

    private var fill: Color {
        switch row.kind {
        case .add: Theme.diffAddFill
        case .remove: Theme.diffRemoveFill
        case .hunk: Theme.diffHunkFill
        case .context: .clear
        }
    }
}

/// "+24 −7": small code, tabular digits, green then red; a zero count is left out.
struct ChangeCounts: View {
    let added: Int
    let removed: Int
    var font: Font? = nil

    var body: some View {
        HStack(spacing: Space.xs) {
            if added > 0 { Text("+\(added)").foregroundStyle(Theme.diffAdd) }
            if removed > 0 { Text("−\(removed)").foregroundStyle(Theme.diffRemove) }
        }
        .font(font ?? TextStyle.codeSmallDigits)
        .lineLimit(1)
        .fixedSize()
    }
}

/// "Open in editor": an accent text button that opens a path (absolute, or relative to the
/// chat's folder) in the user's default app for it.
struct OpenInEditor: View {
    let path: String
    var folder: URL?
    var title = "Open in editor"

    var body: some View {
        TextButton(title) { NSWorkspace.shared.open(Self.url(path, in: folder)) }
            .help("Open in editor")
    }

    static func url(_ path: String, in folder: URL?) -> URL {
        guard let folder, !path.hasPrefix("/") else { return URL(fileURLWithPath: path) }
        return folder.appendingPathComponent(path)
    }
}

/// An accent text button, underlined on hover ("View changes", "Show all", "Open in editor").
struct TextButton: View {
    let title: String
    var font: Font = TextStyle.labelMedium
    var color: Color = Theme.accent
    let action: () -> Void
    @StateObject private var hovered = Local(false)

    init(_ title: String, font: Font = TextStyle.labelMedium, color: Color = Theme.accent, action: @escaping () -> Void) {
        self.title = title
        self.font = font
        self.color = color
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(font)
                .foregroundStyle(color)
                .underline(hovered.value)
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
    }
}
