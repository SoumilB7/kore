import AppKit
import Observation
import SwiftUI

/// The editor's find and replace (look §5): every match found at once, shown as a fill, the
/// current one stronger and selected. Case, whole word and regex toggles; replace one or all,
/// each one undoable step.
@MainActor @Observable
final class FindModel {
    var isOpen = false
    var showReplace = false
    var query = "" {
        didSet { if query != oldValue { search() } }
    }
    var replacement = ""
    var caseSensitive = false {
        didSet { search() }
    }
    var wholeWord = false {
        didSet { search() }
    }
    var regex = false {
        didSet { search() }
    }
    private(set) var matches: [NSRange] = []
    private(set) var current: Int?
    /// The regex doesn't compile.
    private(set) var invalid = false
    /// Bumped to put the caret back in the field.
    private(set) var focusRequest = 0

    @ObservationIgnored weak var controller: CodeEditorController?
    @ObservationIgnored private var expression: NSRegularExpression?
    @ObservationIgnored private var highlighted: [NSRange] = []
    @ObservationIgnored private var researchQueued = false
    /// More than this many matches stop counting ("10000+").
    static let cap = 10_000
    /// Fills drawn for at most this many matches.
    private static let highlightCap = 2_000

    var countLabel: String {
        if query.isEmpty { return "" }
        if matches.isEmpty { return "No results" }
        let total = matches.count >= Self.cap ? "\(Self.cap)+" : "\(matches.count)"
        return "\((current ?? 0) + 1) of \(total)"
    }

    func open(replace: Bool) {
        if let text = controller?.textView, text.selectedRange().length > 0 {
            let selected = (text.string as NSString).substring(with: text.selectedRange())
            if !selected.contains("\n") { query = selected }
        }
        if replace { showReplace = true }
        isOpen = true
        focusRequest += 1
        search()
    }

    func close() {
        isOpen = false
        clearHighlights()
        matches = []
        current = nil
        controller?.focus()
    }

    /// ⌘E: the selection becomes the query, without opening the bar.
    func useSelection() {
        guard let text = controller?.textView, text.selectedRange().length > 0 else { return }
        query = (text.string as NSString).substring(with: text.selectedRange())
    }

    // MARK: Searching

    func search() {
        guard isOpen, let controller else { return }
        clearHighlights()
        matches = []
        current = nil
        invalid = false
        expression = nil
        guard !query.isEmpty else { return }
        var pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
        if wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
        guard let expression = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else {
            invalid = true
            return
        }
        self.expression = expression
        let string = controller.document.storage.string
        var found: [NSRange] = []
        expression.enumerateMatches(in: string, range: NSRange(location: 0, length: (string as NSString).length)) { result, _, stop in
            guard let range = result?.range, range.length > 0 else { return }
            found.append(range)
            if found.count >= Self.cap { stop.pointee = true }
        }
        matches = found
        let caret = controller.textView.selectedRange().location
        current = found.isEmpty ? nil : (found.firstIndex { $0.location >= caret } ?? 0)
        highlight()
    }

    /// After an edit: once, when the edits of this turn of the run loop are done.
    func textChanged() {
        guard isOpen, !researchQueued else { return }
        researchQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            researchQueued = false
            let keep = current
            search()
            if let keep, !matches.isEmpty { current = min(keep, matches.count - 1) }
            highlight()
        }
    }

    func next() { step(1) }
    func previous() { step(-1) }

    private func step(_ delta: Int) {
        if !isOpen { open(replace: false) }
        guard !matches.isEmpty else { return }
        current = ((current ?? -delta) + delta + matches.count) % matches.count
        highlight()
        reveal()
    }

    private func reveal() {
        guard let current, let text = controller?.textView else { return }
        text.setSelectedRange(matches[current])
        text.scrollRangeToVisible(matches[current])
    }

    // MARK: Replacing

    func replaceOne() {
        guard let current, let expression, let text = controller?.textView else { return }
        let range = matches[current]
        let found = (text.string as NSString).substring(with: range)
        let with = regex
            ? expression.stringByReplacingMatches(in: found, range: NSRange(location: 0, length: (found as NSString).length), withTemplate: replacement)
            : replacement
        guard text.shouldChangeText(in: range, replacementString: with) else { return }
        text.textStorage?.replaceCharacters(in: range, with: with)
        text.didChangeText()
        search()
        if !matches.isEmpty {
            self.current = matches.firstIndex { $0.location >= range.location + (with as NSString).length } ?? 0
            highlight()
            reveal()
        }
    }

    func replaceAll() {
        guard let expression, !matches.isEmpty, let controller else { return }
        let text = controller.textView
        let template = regex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        controller.undo.beginUndoGrouping()
        // From the end, so earlier ranges stay put.
        for range in matches.reversed() {
            let found = (text.string as NSString).substring(with: range)
            let with = expression.stringByReplacingMatches(
                in: found, range: NSRange(location: 0, length: (found as NSString).length), withTemplate: template)
            guard text.shouldChangeText(in: range, replacementString: with) else { continue }
            text.textStorage?.replaceCharacters(in: range, with: with)
            text.didChangeText()
        }
        controller.undo.endUndoGrouping()
        search()
    }

    // MARK: Fills

    private func highlight() {
        clearHighlights()
        guard let layout = controller?.textView.layoutManager else { return }
        let shown = matches.prefix(Self.highlightCap)
        for (index, range) in shown.enumerated() {
            let color = index == current ? Theme.Editor.findCurrent : Theme.Editor.findMatch
            layout.addTemporaryAttribute(.backgroundColor, value: NSColor(color), forCharacterRange: range)
        }
        if let current, current >= Self.highlightCap {
            layout.addTemporaryAttribute(.backgroundColor, value: NSColor(Theme.Editor.findCurrent), forCharacterRange: matches[current])
        }
        highlighted = Array(shown)
        if let current { highlighted.append(matches[current]) }
    }

    private func clearHighlights() {
        guard let controller, let layout = controller.textView.layoutManager else { return }
        let length = controller.document.storage.length
        for range in highlighted {
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSIntersectionRange(range, NSRange(location: 0, length: length)))
        }
        highlighted = []
    }
}

// MARK: - The bar

/// The find bar at the editor's top-right (look §5).
struct FindBar: View {
    let find: FindModel
    @FocusState private var field: Field?

    private enum Field { case query, replacement }

    var body: some View {
        @Bindable var find = find
        HStack(alignment: .top, spacing: Space.xs) {
            IconButton(symbol: find.showReplace ? "chevron.down" : "chevron.right", kind: .small, font: Chrome.glyphTreeChevron,
                       help: "Replace") { find.showReplace.toggle() }
            VStack(spacing: Space.xs) {
                HStack(spacing: Space.xs) {
                    HStack(spacing: Space.xxs) {
                        TextField("Find", text: $find.query)
                            .textFieldStyle(.plain)
                            .font(Chrome.body)
                            .foregroundStyle(Theme.text)
                            .focused($field, equals: .query)
                            .onSubmit { find.next() }
                            .onKeyPress(.return, phases: .down) { press in
                                guard press.modifiers.contains(.shift) else { return .ignored }
                                find.previous()
                                return .handled
                            }
                        Toggle(label: "Aa", isOn: find.caseSensitive, help: "Match Case") { find.caseSensitive.toggle() }
                        Toggle(label: "ab", isOn: find.wholeWord, underline: true, help: "Match Whole Word") { find.wholeWord.toggle() }
                        Toggle(label: ".*", isOn: find.regex, help: "Use Regular Expression") { find.regex.toggle() }
                    }
                    .modifier(FindField(failed: find.invalid || (!find.query.isEmpty && find.matches.isEmpty), focused: field == .query))
                    Text(find.countLabel)
                        .font(Chrome.labelDigits)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    IconButton(symbol: "arrow.up", kind: .small, font: Chrome.label, help: "Previous Match (⇧⌘G)") { find.previous() }
                        .disabled(find.matches.isEmpty)
                    IconButton(symbol: "arrow.down", kind: .small, font: Chrome.label, help: "Next Match (⌘G)") { find.next() }
                        .disabled(find.matches.isEmpty)
                    IconButton(symbol: "xmark", kind: .small, font: Chrome.label, help: "Close (Esc)") { find.close() }
                }
                if find.showReplace {
                    HStack(spacing: Space.xs) {
                        TextField("Replace", text: $find.replacement)
                            .textFieldStyle(.plain)
                            .font(Chrome.body)
                            .foregroundStyle(Theme.text)
                            .focused($field, equals: .replacement)
                            .onSubmit { find.replaceOne() }
                            .modifier(FindField(failed: false, focused: field == .replacement))
                        IconButton(symbol: "arrow.turn.down.right", kind: .small, font: Chrome.label, help: "Replace (⇧⌘1)") {
                            find.replaceOne()
                        }
                        .keyboardShortcut("1", modifiers: [.command, .shift])
                        .disabled(find.current == nil)
                        IconButton(symbol: "text.badge.checkmark", kind: .small, font: Chrome.label, help: "Replace All (⌥⌘↩)") {
                            find.replaceAll()
                        }
                        .keyboardShortcut(.return, modifiers: [.command, .option])
                        .disabled(find.matches.isEmpty)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(Inset.floatingBar)
        .frame(maxWidth: Size.Editor.find)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Theme.border, lineWidth: Stroke.hairline))
        .onExitCommand { find.close() }
        .onAppear { field = .query }
        .onChange(of: find.focusRequest) { field = .query }
    }
}

private struct FindField: ViewModifier {
    let failed: Bool
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Space.sm)
            .frame(height: Size.iconButtonSmall)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Radius.chip))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.chip)
                    .strokeBorder(failed ? Theme.danger : (focused ? Theme.borderFocused : Theme.border), lineWidth: Stroke.hairline)
            )
    }
}

/// Case, word and regex toggles inside the field.
private struct Toggle: View {
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

// MARK: - The scroller's ticks

/// A 2pt accent tick on the vertical scroller per match, at its line's place in the file (look
/// §5), so where the matches are shows at a glance. One tick per pixel row however many share it.
struct FindTicks: View {
    let find: FindModel
    let lines: LineIndex

    var body: some View {
        let matches = find.matches
        let count = max(lines.count, 1)
        Canvas { context, size in
            guard !matches.isEmpty, size.height > 0 else { return }
            let tick = Size.Editor.findTick
            let track = size.height - tick.height
            var drawn = Set<Int>()
            for range in matches {
                let y = (CGFloat(lines.line(at: range.location)) / CGFloat(count)) * track
                guard drawn.insert(Int(y)).inserted else { continue }
                context.fill(Path(CGRect(x: 0, y: y, width: tick.width, height: tick.height)), with: .color(Theme.accent))
            }
        }
        .frame(width: Size.Editor.findTick.width)
        .padding(.trailing, Size.Editor.findTickInset)
        .allowsHitTesting(false)
    }
}
