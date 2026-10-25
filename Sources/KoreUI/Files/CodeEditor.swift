import AppKit
import KoreCore
import SwiftUI

/// The editor for one open file: an NSTextView (TextKit 1, laid out only where it's seen) with
/// a line-number gutter, the caret's line, syntax colour for what's on screen, and the
/// editing keys people bring from VS Code. Owned by the document, so it survives tab switches.
@MainActor
final class CodeEditorController: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    unowned let document: FileDocument
    let scrollView = EditorScrollView()
    let textView: EditorTextView
    private let gutter: GutterView
    let lines = LineIndex()
    private var colorer: SyntaxColorer
    private var zoom: CGFloat = 0
    private var wraps: Bool?
    private var colored: ClosedRange<Int>?
    private var flash: Task<Void, Never>?
    /// ⌃G: opens go-to-line (quick open's line mode).
    var onGoToLine: () -> Void = {}
    /// Each file keeps its own undo history, as in VS Code (not the window's).
    let undo = UndoManager()
    let find = FindModel()
    /// The text against git `HEAD`, for the gutter's bars. Worked out off the main thread at
    /// load, save and a reload from disk, and once typing stops; between those, edits move the
    /// marks by the lines they add or remove.
    private(set) var changes = LineChanges()
    private var diffing: Task<Void, Never>?
    /// Bumped by each edit: a diff started before one is stale.
    private var editCount = 0
    /// The peek of one change's old text, under its line.
    private var peek: (line: Int, view: NSView)?
    /// Folded text, sorted: each from the end of a fold's first line to the end of its last
    /// (that line's break stays, so the next line starts below). The text itself is untouched.
    var folds: [NSRange] = []
    /// Where code can fold, worked out at idle.
    var regions = FoldRegions()
    var regionsPending: Task<Void, Never>?

    init(document: FileDocument) {
        self.document = document
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        document.storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        layout.addTextContainer(container)
        textView = EditorTextView(frame: .zero, textContainer: container)
        gutter = GutterView(scrollView: scrollView, orientation: .verticalRuler)
        colorer = SyntaxColorer(language: document.language)
        super.init()
        textView.controller = self
        gutter.controller = self
        find.controller = self
        configure()
        document.storage.delegate = self
        lines.rebuild(document.storage.string as NSString)
        computeRegions()
    }

    private func configure() {
        let text = textView
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        // No Writing Tools / "Write with Siri" badge or inline predictions over Kore's own fields.
        text.writingToolsBehavior = .none
        text.inlinePredictionType = .no
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.isGrammarCheckingEnabled = false
        text.smartInsertDeleteEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.usesFontPanel = false
        // The ground comes from the SwiftUI view behind; a text view that paints its own
        // keeps a second window-sized buffer.
        text.drawsBackground = false
        text.insertionPointColor = NSColor(Theme.Editor.caret)
        text.isVerticallyResizable = true
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.textContainerInset = NSSize(width: Size.Editor.textInsetLeading, height: Size.Editor.textInsetTop)
        text.delegate = self
        // Folded text: no glyphs, and its line breaks don't break lines.
        text.layoutManager?.delegate = self

        // Unclipped views get an overdraw layer the size of the scroll area (macOS 14+).
        scrollView.clipsToBounds = true
        text.clipsToBounds = true
        gutter.clipsToBounds = true
        text.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        scrollView.documentView = text
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        // Only the text view paints the ground: a scroll view or clip view that draws gets
        // a window-sized backing store of its own.
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    // MARK: - Settings from the view

    func setZoom(_ scale: CGFloat) {
        guard scale != zoom else { return }
        zoom = scale
        applyStyle()
    }

    func setWrap(_ wrap: Bool) {
        guard wrap != wraps else { return }
        wraps = wrap
        let container = textView.textContainer!
        if wrap {
            textView.isHorizontallyResizable = false
            container.widthTracksTextView = true
            textView.frame.size.width = scrollView.contentSize.width
            container.size = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        } else {
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
        }
        recolor(force: true)
        textView.updateDecorations()
    }

    func setLanguage(_ language: Language) {
        colorer = SyntaxColorer(language: language)
        recolor(force: true)
    }

    var font: NSFont { TextStyle.editorFont }
    var lineHeight: CGFloat { Size.Editor.line * Zoom.shared.scale }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        let font = font
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        let natural = textView.layoutManager?.defaultLineHeight(for: font) ?? font.pointSize
        return [
            .font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor(Theme.Syntax.plain),
            .baselineOffset: max(0, (lineHeight - natural) / 2),
        ]
    }

    private func applyStyle() {
        defer { textView.updateDecorations() }
        let attributes = baseAttributes
        let storage = document.storage
        storage.beginEditing()
        storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        textView.typingAttributes = attributes
        var selected = textView.selectedTextAttributes
        selected[.backgroundColor] = NSColor(Theme.Editor.selection)
        selected.removeValue(forKey: .foregroundColor)
        textView.selectedTextAttributes = selected
        gutter.updateThickness()
        recolor(force: true)
    }

    // MARK: - Text from the document

    /// The document replaced all its text (load).
    func textReplaced() {
        closePeek()
        refreshChanges()
        lines.rebuild(document.storage.string as NSString)
        folds = []
        scheduleRegions()
        undo.removeAllActions()
        colorer.invalidate(from: 0)
        if zoom != 0 { applyStyle() }
        gutter.updateThickness()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    /// The disk changed and there were no unsaved edits: replace the changed part, keep the
    /// caret, and flash the new lines.
    func replaceFromDisk(_ range: NSRange, with text: String) {
        let selection = textView.selectedRange()
        let storage = document.storage
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: text)
        storage.setAttributes(baseAttributes, range: NSRange(location: range.location, length: (text as NSString).length))
        storage.endEditing()
        // Our undo steps point at text that's gone.
        undo.removeAllActions()
        let delta = (text as NSString).length - range.length
        var caret = selection.location
        if caret > range.location + range.length { caret += delta } else if caret > range.location { caret = range.location }
        textView.setSelectedRange(NSRange(location: min(caret, storage.length), length: 0))
        flashLines(NSRange(location: range.location, length: (text as NSString).length))
        recolor(force: true)
        refreshChanges()
        scheduleRegions()
    }

    private func flashLines(_ range: NSRange) {
        flash?.cancel()
        guard let layout = textView.layoutManager, range.length > 0,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return }
        let lineRange = (document.storage.string as NSString).lineRange(for: range)
        let base = NSColor(Theme.Editor.flash)
        let start = Date()
        let document = document
        flash = Task { [weak self, weak document] in
            while !Task.isCancelled, let self, let document {
                defer { withExtendedLifetime(document) {} }
                let progress = min(1, Date().timeIntervalSince(start) / Motion.flash)
                let safe = NSIntersectionRange(lineRange, NSRange(location: 0, length: document.storage.length))
                if progress >= 1 {
                    layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: safe)
                    return
                }
                // Ease-out to nothing.
                let alpha = base.alphaComponent * pow(1 - progress, 2)
                layout.addTemporaryAttribute(.backgroundColor, value: base.withAlphaComponent(alpha), forCharacterRange: safe)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    // MARK: - Edits

    func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        let before = lines.count
        lines.update(textStorage.string as NSString, edited: editedRange, delta: delta)
        editCount &+= 1
        if !changes.marks.isEmpty || !changes.deletions.isEmpty {
            changes.shift(from: lines.line(at: editedRange.location), by: lines.count - before)
        }
        colorer.invalidate(from: lines.line(at: editedRange.location))
        colored = nil
        foldsEdited(editedRange, delta: delta)
    }

    func textDidChange(_ notification: Notification) {
        closePeek()
        refreshChanges(after: .seconds(1))
        document.edited()
        find.textChanged()
        scheduleRegions()
        recolor()
        textView.updateDecorations()
        gutter.updateThickness()
        gutter.needsDisplay = true
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        !document.readOnly
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        revealSelection()
        let selection = textView.selectedRange()
        let line = lines.line(at: selection.location)
        let column = selection.location - lines.start(of: line) + 1
        let caret = FileDocument.Caret(line: line + 1, column: column, selected: selection.length)
        if document.caret != caret { document.caret = caret }
        textView.bracketPair = textView.findBracketPair()
        textView.updateDecorations()
        gutter.needsDisplay = true
    }

    @objc private func scrolled() {
        recolor()
        textView.updateDecorations()
    }

    // MARK: - Colour

    /// Colours the lines on screen (and a screenful either side), from each line's starting state.
    func recolor(force: Bool = false) {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let storage = document.storage
        guard storage.length > 0 else { return }
        var visible = scrollView.contentView.bounds
        visible.origin.y -= visible.height
        visible.size.height *= 3
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = lines.line(at: chars.location)
        let last = lines.line(at: max(chars.location, NSMaxRange(chars) - 1))
        let range = first...last
        if !force, let colored, colored.contains(range.lowerBound), colored.contains(range.upperBound) { return }
        colored = range
        colorer.color(range, storage: storage, lines: lines, layout: layout)
    }

    // MARK: - Moving around

    /// Selects the document's pending place (a search hit) and scrolls it to the middle.
    func applyPendingPlace() {
        guard let place = document.pendingPlace, document.storage.length > 0 || place.line == 1 else { return }
        document.pendingPlace = nil
        let index = min(max(place.line - 1, 0), lines.count - 1)
        let range = lines.range(of: index, in: document.storage.string as NSString)
        let start = range.location + min(place.columns.lowerBound, range.length)
        let length = min(place.columns.count, NSMaxRange(range) - start)
        let selection = NSRange(location: start, length: max(length, 0))
        textView.setSelectedRange(selection)
        if let layout = textView.layoutManager, let container = textView.textContainer {
            // Centred vertically, as VS Code reveals a match; sideways only when the match is
            // past the right edge (the clip's own left inset, under the gutter, stays).
            let glyphs = layout.glyphRange(forCharacterRange: selection, actualCharacterRange: nil)
            let box = layout.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            let clip = scrollView.contentView
            let visible = clip.bounds
            let left = gutter.textLeft
            let y = max(0, box.midY - visible.height / 2)
            // Back to the left edge unless the match is past the right one.
            var x = left
            if box.maxX > left + visible.width { x = box.maxX - visible.width * 0.7 }
            clip.scroll(to: NSPoint(x: x, y: y))
            scrollView.reflectScrolledClipView(clip)
        }
        recolor(force: true)
        textView.updateDecorations()
    }

    func goTo(line: Int) {
        let index = min(max(line - 1, 0), lines.count - 1)
        let location = lines.start(of: index)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(NSRange(location: location, length: 0))
        textView.window?.makeFirstResponder(textView)
    }

    /// The caret was asked for before the text view was in a window (a file just opened, its
    /// view not built yet): the text view takes it as it moves into one.
    private var focusPending = false

    /// Puts the caret in the editor: now when its text view is in a window, else as it moves
    /// into one.
    func focus() {
        guard let window = textView.window else {
            focusPending = true
            // Or the file's preview, when that's what shows.
            document.rendering.focusPending = true
            return
        }
        focusPending = false
        window.makeFirstResponder(textView)
    }

    /// The text view is in a window now: it takes the caret if that was asked for meanwhile.
    func movedToWindow() {
        guard focusPending, textView.window != nil else { return }
        document.rendering.focusPending = false
        focus()
    }

    func gutterNeedsDisplay() { gutter.needsDisplay = true }

    // MARK: - Changes against git HEAD

    /// Diffs the text against `HEAD` once `delay` passes with no newer call (typing).
    func refreshChanges(after delay: Duration = .zero) {
        diffing?.cancel()
        guard document.isText, !document.readOnly else { return }
        let document = document
        let url = document.url
        diffing = Task { [weak self, weak document] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            guard let self, let document else { return }
            defer { withExtendedLifetime(document) {} }
            let edits = editCount
            let text = document.storage.string
            let result: LineChanges
            if let base = await GitBaseline.head(of: url) {
                result = await GitBaseline.changes(from: base, to: text)
            } else {
                result = LineChanges()
            }
            // Typed over meanwhile: the next pause diffs again.
            guard !Task.isCancelled, edits == editCount else { return }
            if result != changes {
                changes = result
                gutter.needsDisplay = true
            }
        }
    }

    /// Opens (or, on the same line, closes) the old text of the change at 0-based `line`, under
    /// that line, as VS Code's peek does.
    func togglePeek(at line: Int) {
        if peek?.line == line {
            closePeek()
            return
        }
        closePeek()
        guard let hunk = changes.hunk(at: line), let layout = textView.layoutManager else { return }
        let change = FileChange(path: document.url.path, kind: .update, hunks: [hunk])
        let string = document.storage.string as NSString
        // Under the change's last line (a deletion: under the line above where it was).
        let lastNew = hunk.lines.compactMap { $0.kind == .add ? $0.new : nil }.last.map { $0 - 1 } ?? max(line - 1, 0)
        let anchor = min(lastNew, lines.count - 1)
        let start = min(lines.start(of: anchor), max(string.length - 1, 0))
        let glyph = layout.glyphIndexForCharacter(at: start)
        let fragment = string.length == 0 ? .zero : layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let visible = textView.visibleRect
        let width = max(visible.width - 2 * Size.Editor.peekInset, 200)
        let host = NSHostingView(rootView: ChangePeek(change: change, folder: document.url.deletingLastPathComponent()) { [weak self] in
            self?.closePeek()
        })
        host.frame.size.width = width
        let height = host.fittingSize.height
        host.frame = NSRect(
            x: visible.minX + Size.Editor.peekInset, y: fragment.maxY + textView.textContainerOrigin.y, width: width,
            height: height)
        textView.addSubview(host)
        peek = (line, host)
    }

    /// Closes the peek; whether one was open.
    @discardableResult
    func closePeek() -> Bool {
        guard let open = peek else { return false }
        open.view.removeFromSuperview()
        peek = nil
        return true
    }
}

/// One change's old and new lines (the phase 08 DiffView) in a bordered box, with a close ×.
struct ChangePeek: View {
    let change: FileChange
    let folder: URL
    let close: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: Space.xs) {
            IconButton(symbol: "xmark", kind: .small, font: Chrome.label, help: "Close (Esc)", action: close)
            DiffView(change: change, folder: folder)
        }
        .padding(Space.sm)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Radius.chip))
        .overlay(RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Theme.border, lineWidth: Stroke.hairline))
    }
}

// MARK: - The view

/// Hosts the document's editor; a fresh container each time, so a tab switch never pulls the
/// editor out of a view that's still on screen.
struct CodeEditorView: NSViewRepresentable {
    let document: FileDocument
    let zoom: CGFloat
    let wrap: Bool
    let goToLine: () -> Void

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        // Since macOS 14 views draw outside their bounds unless told not to.
        container.clipsToBounds = true
        attach(document.editor.scrollView, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let editor = document.editor
        if editor.scrollView.superview !== container { attach(editor.scrollView, to: container) }
        editor.onGoToLine = goToLine
        editor.setZoom(zoom)
        editor.setWrap(wrap)
        if document.pendingPlace != nil {
            // After this layout pass, so the text is laid out to scroll to.
            DispatchQueue.main.async { editor.applyPendingPlace() }
        }
    }

    private func attach(_ scrollView: NSScrollView, to container: NSView) {
        scrollView.removeFromSuperview()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        for view in container.subviews { view.removeFromSuperview() }
    }
}

// MARK: - Lines

/// Where each line starts (UTF-16 offsets), kept up to date edit by edit. A line ends where
/// NSString's `getLineStart` ends one: at `\n`, `\r\n` (one break), a lone `\r`, or U+2028 /
/// U+2029, so the gutter, go-to-line, find ticks and the caret's line agree with AppKit's.
final class LineIndex: @unchecked Sendable {
    private(set) var starts: [Int] = [0]

    var count: Int { starts.count }

    func start(of line: Int) -> Int { starts[min(max(line, 0), starts.count - 1)] }

    /// The 0-based line holding `offset`.
    func line(at offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The line's range without its line break (two characters for `\r\n`).
    func range(of line: Int, in string: NSString) -> NSRange {
        let start = self.start(of: line)
        var end = string.length
        if line + 1 < starts.count {
            end = starts[line + 1] - 1
            if end > start, string.character(at: end) == Self.lf, string.character(at: end - 1) == Self.cr { end -= 1 }
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    func rebuild(_ string: NSString) {
        starts = [0]
        starts.append(contentsOf: Self.newlines(in: string, range: NSRange(location: 0, length: string.length)))
    }

    /// After `edited` (in the new text) replaced `edited.length - delta` characters. Only the
    /// edit is scanned, with one character either side: a `\r\n` pair can be joined or split
    /// at its edges.
    func update(_ string: NSString, edited: NSRange, delta: Int) {
        let from = max(0, edited.location - 1)
        let to = min(string.length, NSMaxRange(edited) + 1)
        // The same span before the edit: its line starts are the ones replaced.
        let oldTo = min(string.length - delta, NSMaxRange(edited) - delta + 1)
        let low = firstIndex(after: from)
        let high = firstIndex(after: oldTo)
        let added = Self.newlines(in: string, range: NSRange(location: from, length: to - from))
        starts.replaceSubrange(low..<high, with: added)
        if delta != 0 {
            for i in (low + added.count)..<starts.count { starts[i] += delta }
        }
    }

    private func firstIndex(after offset: Int) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The offsets after each line break that ends in `range`. A `\r` is a break of its own
    /// unless a `\n` follows it (looked up past the range when it's the last character).
    static func newlines(in string: NSString, range: NSRange) -> [Int] {
        var result: [Int] = []
        let chunk = 1 << 16
        var buffer = [unichar](repeating: 0, count: chunk)
        var location = range.location
        let end = NSMaxRange(range)
        while location < end {
            let length = min(chunk, end - location)
            string.getCharacters(&buffer, range: NSRange(location: location, length: length))
            for i in 0..<length {
                switch buffer[i] {
                case lf, ls, ps:
                    result.append(location + i + 1)
                case cr:
                    let next = location + i + 1
                    let followed = i + 1 < length ? buffer[i + 1] == lf : next < string.length && string.character(at: next) == lf
                    if !followed { result.append(next) }
                default:
                    break
                }
            }
            location += length
        }
        return result
    }

    /// The text ends in a line break, so the caret after it sits on a line of its own.
    static func endsWithBreak(_ string: NSString) -> Bool {
        guard string.length > 0 else { return false }
        let last = string.character(at: string.length - 1)
        return last == lf || last == cr || last == ls || last == ps
    }

    static let lf: unichar = 0x0A
    static let cr: unichar = 0x0D
    /// U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR.
    static let ls: unichar = 0x2028
    static let ps: unichar = 0x2029
}

// MARK: - Syntax colour

/// Colours lines with the language's scanner, as temporary attributes (not part of the text
/// or its undo). Each line's starting state is kept, so colouring line 5,000 scans only the
/// states of the lines above it, and an edit re-scans from its own line.
@MainActor
final class SyntaxColorer {
    let language: Language
    /// The state at the start of line i, known for i < states.count.
    private var states: [Language.State] = [.normal]
    /// Lines longer than this aren't coloured (minified files); VS Code stops at 20k.
    private static let longLine = 10_000

    init(language: Language) { self.language = language }

    func invalidate(from line: Int) {
        if states.count > line + 1 { states.removeSubrange((line + 1)...) }
    }

    func color(_ range: ClosedRange<Int>, storage: NSTextStorage, lines: LineIndex, layout: NSLayoutManager) {
        let string = storage.string as NSString
        guard language.family != .plain else { return }
        var buffer: [UInt16] = []
        func characters(_ line: Int) -> (NSRange, [UInt16]) {
            let lineRange = lines.range(of: line, in: string)
            let length = min(lineRange.length, Self.longLine)
            buffer = [UInt16](repeating: 0, count: length)
            string.getCharacters(&buffer, range: NSRange(location: lineRange.location, length: length))
            return (lineRange, buffer)
        }
        // States down to the first line, cheaply.
        while states.count <= range.lowerBound {
            let line = states.count - 1
            let (lineRange, chars) = characters(line)
            states.append(lineRange.length > Self.longLine ? .normal : language.endState(chars, from: states[line]))
        }
        var tokens: [Language.Token] = []
        for line in range {
            let (lineRange, chars) = characters(line)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: lineRange)
            tokens.removeAll(keepingCapacity: true)
            let end: Language.State
            if lineRange.length > Self.longLine {
                end = .normal
            } else {
                end = language.scan(chars, from: states[line], into: &tokens)
                for token in tokens {
                    guard let color = Theme.Syntax.color(token.kind) else { continue }
                    layout.addTemporaryAttribute(
                        .foregroundColor, value: color,
                        forCharacterRange: NSRange(location: lineRange.location + token.range.lowerBound, length: token.range.count))
                }
            }
            if line + 1 < states.count {
                if states[line + 1] != end {
                    states[line + 1] = end
                    states.removeSubrange((line + 2)...)
                }
            } else if line + 1 == states.count {
                states.append(end)
            }
        }
    }
}

// MARK: - The gutter

/// The editor's scroll view. The clip runs under the gutter and its left inset (the gutter's
/// width) only exists once the view is laid out at a real size; until then its origin is 0,
/// which then leaves the first columns, and the caret on an empty line, under the gutter.
final class EditorScrollView: NSScrollView {
    override func tile() {
        let clip = contentView
        let first = clip.bounds.width == 0
        super.tile()
        guard first, clip.bounds.width > 0, clip.bounds.origin.x > -clip.contentInsets.left else { return }
        clip.scroll(to: NSPoint(x: -clip.contentInsets.left, y: clip.bounds.origin.y))
        reflectScrolledClipView(clip)
    }
}

/// Line numbers, right-aligned, the caret's line brighter, and git change bars at the right
/// edge (look §4); a click on a bar opens its peek.
final class GutterView: NSRulerView {
    weak var controller: CodeEditorController?
    /// Fold chevrons show while the pointer is over the gutter (a folded line's always).
    private var hovering = false

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    @MainActor func updateThickness() {
        guard let controller else { return }
        let digits = max(Size.Editor.gutterDigits, String(controller.lines.count).count)
        let width = ("8" as NSString).size(withAttributes: [.font: controller.font]).width
        let thickness = ceil(Size.Editor.gutterLeading + CGFloat(digits) * width + Size.Editor.gutterTrailing)
        guard ruleThickness != thickness, let scrollView else { return }
        // The clip view runs under the gutter, its bounds shifted left by the gutter's width.
        // A change after the scroll view is on screen doesn't move them, so text would sit
        // under the gutter: retile, and keep a view that was at the left edge at the new edge.
        let clip = scrollView.contentView
        let atLeft = clip.bounds.origin.x <= -ruleThickness + 0.5
        ruleThickness = thickness
        scrollView.tile()
        if atLeft {
            clip.scroll(to: NSPoint(x: -thickness, y: clip.bounds.origin.y))
            scrollView.reflectScrolledClipView(clip)
        }
        controller.recolor(force: true)
    }

    /// Where the text starts in the clip view: left of it is under the gutter.
    var textLeft: CGFloat { -ruleThickness }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(Theme.background).setFill()
        dirtyRect.fill()
        drawHashMarksAndLabels(in: dirtyRect)
        if StoryHost.installed { MainActor.assumeIsolated { registerChevrons() } }
    }

    /// Storylines: each foldable line on screen, registered by line (`editor.gutter.fold[n]`)
    /// with its chevron's box and the fold it toggles, whether or not the chevron is drawn.
    private var storyChevrons: [Int: StoryRegistry.Token] = [:]

    @MainActor private func registerChevrons() {
        guard let controller, let layout = controller.textView.layoutManager, let container = controller.textView.textContainer
        else { return }
        let text = controller.textView
        let glyphs = layout.glyphRange(forBoundingRect: text.visibleRect, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let lines = controller.lines
        var shown = Set<Int>()
        var line = lines.line(at: chars.location)
        let last = lines.line(at: NSMaxRange(chars))
        while line <= last {
            if let fold = controller.hiddenFold(line: line) {
                line = lines.line(at: NSMaxRange(fold)) + 1
                continue
            }
            if controller.regions.end(of: line) != nil || controller.fold(startingOn: line) != nil { shown.insert(line) }
            line += 1
        }
        for (line, token) in storyChevrons where !shown.contains(line) {
            StoryRegistry.unregister(token)
            storyChevrons[line] = nil
        }
        for line in shown where storyChevrons[line] == nil {
            storyChevrons[line] = StoryRegistry.register(
                StoryID.Editor.gutterFold(line).raw, in: self,
                rect: { [weak self] in MainActor.assumeIsolated { self?.chevronBox(line) } },
                press: { [weak self] in self?.controller?.toggleFold(line: line) })
        }
    }

    /// The chevron's box on a line: the trailing space left of the change bars.
    @MainActor private func chevronBox(_ line: Int) -> NSRect? {
        guard let controller, let top = lineTop(line) else { return nil }
        let box = Size.Editor.gutterTrailing - Size.Editor.changeBar
        return NSRect(x: ruleThickness - Size.Editor.gutterTrailing, y: top, width: box, height: controller.lineHeight)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        MainActor.assumeIsolated { drawNumbers(in: rect) }
    }

    @MainActor private func drawNumbers(in rect: NSRect) {
        guard let controller, let text = clientView as? NSTextView ?? controller.textView as NSTextView?,
            let layout = text.layoutManager, let container = text.textContainer
        else { return }
        let string = text.string as NSString
        let lines = controller.lines
        let visible = text.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let caretLine = lines.line(at: text.selectedRange().location)
        let font = controller.font
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(Theme.Editor.lineNumber)]
        let current: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(Theme.Editor.lineNumberCurrent)]
        let origin = text.textContainerOrigin
        let right = ruleThickness - Size.Editor.gutterTrailing
        var line = lines.line(at: chars.location)
        let last = lines.line(at: NSMaxRange(chars))
        while line <= last {
            // Lines under a fold have no row of their own.
            if let fold = controller.hiddenFold(line: line) {
                line = lines.line(at: NSMaxRange(fold)) + 1
                continue
            }
            let start = lines.start(of: line)
            var fragment: NSRect
            if start >= string.length, string.length > 0 || line > 0 {
                fragment = layout.extraLineFragmentRect
                if fragment.height == 0 { break }
            } else {
                let glyph = layout.glyphIndexForCharacter(at: start)
                fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            }
            let y = convert(NSPoint(x: 0, y: fragment.minY + origin.y), from: text).y
            if y > rect.maxY { break }
            drawChange(line, controller.changes, top: y, layout: layout, string: string)
            if line == lines.count - 1, controller.changes.deletions.contains(lines.count) {
                drawDeletion(at: y + controller.lineHeight)
            }
            let label = String(line + 1) as NSString
            let attributes = line == caretLine ? current : plain
            let size = label.size(withAttributes: attributes)
            let baseline = (controller.lineHeight - size.height) / 2
            label.draw(at: NSPoint(x: right - size.width, y: y + baseline), withAttributes: attributes)
            drawChevron(line, top: y)
            line += 1
        }
    }

    /// A fold chevron in the trailing space, left of the bars: down where a region can fold,
    /// right where it's folded.
    @MainActor private func drawChevron(_ line: Int, top: CGFloat) {
        guard let controller, controller.regions.end(of: line) != nil else { return }
        let folded = controller.fold(startingOn: line) != nil
        guard folded || hovering else { return }
        let config = NSImage.SymbolConfiguration(pointSize: Size.Editor.foldChevron, weight: .semibold)
            .applying(.init(paletteColors: [NSColor(Theme.secondary)]))
        guard let image = NSImage(systemSymbolName: folded ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        else { return }
        let box = Size.Editor.gutterTrailing - Size.Editor.changeBar
        let x = ruleThickness - Size.Editor.gutterTrailing + (box - image.size.width) / 2
        image.draw(in: NSRect(
            x: x, y: top + (controller.lineHeight - image.size.height) / 2, width: image.size.width, height: image.size.height))
    }

    /// The line's bar (all its wrapped rows), and a deletion's triangle on its top edge. A
    /// folded line shows a bar when a line under it changed, as in VS Code.
    @MainActor private func drawChange(_ line: Int, _ changes: LineChanges, top: CGFloat, layout: NSLayoutManager, string: NSString) {
        guard let controller else { return }
        var mark = changes.marks[line]
        if mark == nil, let fold = controller.fold(startingOn: line) {
            let end = controller.lines.line(at: NSMaxRange(fold))
            if changes.marks.keys.contains(where: { $0 > line && $0 <= end }) { mark = .modified }
        }
        if let mark {
            var height = controller.lineHeight
            let range = controller.lines.range(of: line, in: string)
            if range.length > 0, let container = controller.textView.textContainer {
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                height = max(height, layout.boundingRect(forGlyphRange: glyphs, in: container).height)
            }
            NSColor(mark == .added ? Theme.Git.added : Theme.Git.modified).setFill()
            NSRect(x: ruleThickness - Size.Editor.changeBar, y: top, width: Size.Editor.changeBar, height: height).fill()
        }
        if changes.deletions.contains(line) { drawDeletion(at: top) }
    }

    private func drawDeletion(at y: CGFloat) {
        let size = Size.Editor.deletionMark
        let x = ruleThickness - size
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: y - size))
        path.line(to: NSPoint(x: x + size, y: y))
        path.line(to: NSPoint(x: x, y: y + size))
        path.close()
        NSColor(Theme.Git.deleted).setFill()
        path.fill()
    }

    /// A bar answers the first click, as the text beside it does.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A click near the right edge on a changed line, or a deletion's triangle, opens its peek;
    /// left of the bars, a fold chevron folds or unfolds its line. Each reaches `Size.hitTarget`
    /// into the gutter: the bars across a line with no chevron, and the chevron over the line's
    /// number, the bars keeping their own strip at the edge.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let handled = MainActor.assumeIsolated { () -> Bool in
            guard let controller, let line = line(at: point.y) else { return false }
            let fromEdge = ruleThickness - point.x
            let bars = Size.Editor.changeBar + Size.Editor.changeBarGap
            let chevron = chevronLine(line)
            if fromEdge <= (chevron == nil ? Size.hitTarget : bars), let target = peekTarget(line, at: point.y) {
                controller.togglePeek(at: target)
                return true
            }
            guard let chevron, fromEdge <= bars + Size.hitTarget else { return false }
            controller.toggleFold(line: chevron)
            return true
        }
        if !handled { super.mouseDown(with: event) }
    }

    /// The changed line a click on a line's bars opens: near the line's top edge, a deletion
    /// above it wins.
    @MainActor private func peekTarget(_ line: Int, at y: CGFloat) -> Int? {
        guard let changes = controller?.changes else { return nil }
        let top = lineTop(line) ?? y
        if changes.deletions.contains(line) && y - top < Size.Editor.deletionMark * 2 { return line }
        if changes.marks[line] != nil { return line }
        return changes.deletions.contains(line + 1) ? line + 1 : nil
    }

    /// The line whose fold chevron is on a line's row, if there's one: a folded row's hidden
    /// lines are its first line's.
    @MainActor private func chevronLine(_ line: Int) -> Int? {
        guard let controller else { return nil }
        var line = line
        if let fold = controller.hiddenFold(line: line) ?? controller.fold(containing: controller.lines.start(of: line)) {
            line = controller.lines.line(at: fold.location)
        }
        return controller.regions.end(of: line) != nil || controller.fold(startingOn: line) != nil ? line : nil
    }

    /// The 0-based line at a height in the gutter.
    @MainActor private func line(at y: CGFloat) -> Int? {
        guard let controller, let layout = controller.textView.layoutManager, let container = controller.textView.textContainer
        else { return nil }
        let text = controller.textView
        let point = convert(NSPoint(x: 0, y: y), to: text)
        let inContainer = NSPoint(x: 0, y: point.y - text.textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: inContainer, in: container)
        return controller.lines.line(at: layout.characterIndexForGlyph(at: glyph))
    }

    /// A line's top in the gutter.
    @MainActor private func lineTop(_ line: Int) -> CGFloat? {
        guard let controller, let layout = controller.textView.layoutManager else { return nil }
        let text = controller.textView
        let start = controller.lines.start(of: line)
        guard start < (text.string as NSString).length else { return nil }
        let glyph = layout.glyphIndexForCharacter(at: start)
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
        return convert(NSPoint(x: 0, y: fragment.minY + text.textContainerOrigin.y), from: text).y
    }
}

// MARK: - The text view

/// NSTextView with the editing keys of VS Code: auto-indent, tab stops, closing pairs,
/// comment toggling, moving and copying lines, and the caret's line drawn behind the text.
final class EditorTextView: NSTextView {
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        // AppKit's prose extras have no place in code: Speech, Layout Orientation, Substitutions.
        let prose: Set<Selector> = [
            #selector(startSpeaking(_:)), #selector(changeLayoutOrientation(_:)), #selector(orderFrontSubstitutionsPanel(_:)),
        ]
        for item in menu.items where item.submenu?.items.contains(where: { $0.action.map(prose.contains) == true }) == true {
            menu.removeItem(item)
        }
        return OptionsMenu.shared.showNative(menu, event: event, view: self) ? nil : menu
    }

    weak var controller: CodeEditorController?

    /// Esc closes an open change peek first.
    override func cancelOperation(_ sender: Any?) {
        // NSTextView has no base cancelOperation implementation to forward to.
        _ = MainActor.assumeIsolated { controller?.closePeek() }
    }

    private var indentUnit: String { MainActor.assumeIsolated { controller?.document.indent.unit ?? "    " } }
    private var language: Language { MainActor.assumeIsolated { controller?.document.language ?? .plain } }
    private var nsString: NSString { string as NSString }

    // MARK: Drawing

    /// The bracket at the caret and its match, outlined.
    var bracketPair: (Int, Int)?

    // Decorations are shape layers behind the text: drawing them in the view (draw or
    // drawBackground) gives the text view a second window-sized bitmap.
    private let lineLayer = CALayer()
    private let guideLayer = CAShapeLayer()
    private let occurrenceLayer = CAShapeLayer()
    private let bracketLayer = CAShapeLayer()
    /// The " ⋯ " chips after folded lines, and where they are (a click opens the fold).
    private let foldLayer = CALayer()
    private var foldChips: [(rect: NSRect, fold: NSRange)] = []
    /// Storylines: the chips' registrations (`editor.foldchip[n]`), placed again with them.
    private var storyChips: [StoryRegistry.Token] = []

    private func installDecorations(in host: CALayer) {
        guard lineLayer.superlayer !== host else { return }
        for (index, layer) in [lineLayer, guideLayer, occurrenceLayer, bracketLayer, foldLayer].enumerated() {
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "hidden": NSNull(), "frame": NSNull()]
            host.insertSublayer(layer, at: UInt32(index))
        }
        lineLayer.backgroundColor = NSColor(Theme.Editor.currentLine).cgColor
        guideLayer.fillColor = NSColor(Theme.Tree.guide).cgColor
        occurrenceLayer.fillColor = NSColor(Theme.Editor.occurrence).cgColor
        bracketLayer.fillColor = nil
        bracketLayer.strokeColor = NSColor(Theme.Editor.bracket).cgColor
        bracketLayer.lineWidth = Stroke.hairline
    }

    /// Redraws the decorations for what's on screen: the caret's line, indent guides, other
    /// occurrences of the selected word, and the bracket pair.
    func updateDecorations() {
        guard let host = layer, let layout = layoutManager, let container = textContainer else { return }
        installDecorations(in: host)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let visibleRect = self.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visibleRect, in: container)
        let visible = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        if window?.firstResponder === self, selectedRange().length == 0, let box = currentLineRect(layout) {
            lineLayer.isHidden = false
            lineLayer.frame = NSRect(x: bounds.minX, y: box.minY, width: bounds.width, height: box.height)
        } else {
            lineLayer.isHidden = true
        }
        guideLayer.path = guidePath(visible, layout: layout)
        occurrenceLayer.path = occurrencePath(visible, layout: layout)
        bracketLayer.path = bracketPath(layout)
        placeFoldChips(visible, layout: layout)
    }

    private func placeFoldChips(_ visible: NSRange, layout: NSLayoutManager) {
        let (folds, height) = MainActor.assumeIsolated { (controller?.folds ?? [], controller?.lineHeight ?? Size.Editor.line) }
        foldChips = []
        foldLayer.sublayers = nil
        let size = Size.Editor.foldChip
        for fold in folds where fold.location >= visible.location && fold.location <= NSMaxRange(visible) {
            let glyph = layout.glyphIndexForCharacter(at: fold.location)
            let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            let frame = NSRect(
                x: textContainerOrigin.x + used.maxX + Size.Editor.foldChipGap,
                y: textContainerOrigin.y + line.minY + (max(line.height, height) - size.height) / 2,
                width: size.width, height: size.height)
            let chip = CATextLayer()
            chip.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
            chip.frame = frame
            chip.backgroundColor = NSColor(Theme.surface).cgColor
            chip.cornerRadius = Radius.chip
            chip.string = "⋯"
            chip.font = NSFont.systemFont(ofSize: 0)
            chip.fontSize = Size.Editor.foldChip.height - Size.Editor.foldChipGap
            chip.foregroundColor = NSColor(Theme.secondary).cgColor
            chip.alignmentMode = .center
            chip.contentsScale = window?.backingScaleFactor ?? 2
            foldLayer.addSublayer(chip)
            foldChips.append((frame, fold))
        }
        if StoryHost.installed { MainActor.assumeIsolated { registerChips() } }
    }

    @MainActor private func registerChips() {
        storyChips.forEach(StoryRegistry.unregister)
        storyChips = foldChips.compactMap { chip in
            guard let controller else { return nil }
            let line = controller.lines.line(at: chip.fold.location)
            let fold = chip.fold
            return StoryRegistry.register(
                StoryID.Editor.foldChip(line).raw, in: self, rect: { chip.rect },
                press: { [weak self] in self?.controller?.unfold(fold) })
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let chip = foldChips.first(where: { $0.rect.contains(point) }) {
            MainActor.assumeIsolated { controller?.unfold(chip.fold) }
            return
        }
        super.mouseDown(with: event)
    }

    private func rect(for range: NSRange, layout: NSLayoutManager) -> NSRect {
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: glyphs, in: textContainer!).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    private func currentLineRect(_ layout: NSLayoutManager) -> NSRect? {
        let string = nsString
        let caret = selectedRange().location
        var box: NSRect
        if caret >= string.length, string.length == 0 || LineIndex.endsWithBreak(string) {
            box = layout.extraLineFragmentRect.offsetBy(dx: 0, dy: textContainerOrigin.y)
        } else {
            box = rect(for: string.lineRange(for: NSRange(location: caret, length: 0)), layout: layout)
            box.size.height = max(box.height, MainActor.assumeIsolated { controller?.lineHeight ?? 18 })
        }
        return box.height > 0 ? box : nil
    }

    /// 1pt lines at each indent stop, as in the tree; a blank line keeps the line above's.
    private func guidePath(_ visible: NSRange, layout: NSLayoutManager) -> CGPath? {
        guard let controller = MainActor.assumeIsolated({ controller }) else { return nil }
        let string = nsString
        let lines = MainActor.assumeIsolated { controller.lines }
        let unit = max(1, MainActor.assumeIsolated { controller.document.indent }.width)
        let height = MainActor.assumeIsolated { controller.lineHeight }
        let space = (" " as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 12)]).width
        let left = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
        let path = CGMutablePath()
        var line = lines.line(at: visible.location)
        let last = lines.line(at: NSMaxRange(visible))
        var carried = 0
        while line <= last {
            if let fold = MainActor.assumeIsolated({ controller.hiddenFold(line: line) }) {
                line = lines.line(at: NSMaxRange(fold)) + 1
                continue
            }
            let range = lines.range(of: line, in: string)
            var columns = 0
            var blank = true
            var i = range.location
            while i < NSMaxRange(range) {
                let c = string.character(at: i)
                if c == .space { columns += 1 } else if c == .tab { columns += unit - columns % unit } else {
                    blank = false
                    break
                }
                i += 1
            }
            if blank { columns = carried } else { carried = columns }
            let levels = columns / unit
            if levels > 0 {
                let box = rect(for: range, layout: layout)
                for level in 0..<levels {
                    path.addRect(CGRect(x: left + CGFloat(level * unit) * space, y: box.minY, width: Stroke.hairline, height: max(box.height, height)))
                }
            }
            line += 1
        }
        return path
    }

    /// Other places the selected word appears, on screen.
    private func occurrencePath(_ visible: NSRange, layout: NSLayoutManager) -> CGPath? {
        let selection = selectedRange()
        guard selection.length > 0, selection.length <= 100, NSMaxRange(selection) <= nsString.length else { return nil }
        let string = nsString
        let word = string.substring(with: selection)
        guard word.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) else { return nil }
        let path = CGMutablePath()
        var search = visible
        while search.length > 0 {
            let found = string.range(of: word, options: [.literal], range: search)
            guard found.location != NSNotFound else { break }
            let before = found.location > 0 ? string.character(at: found.location - 1) : 0x20
            let after = NSMaxRange(found) < string.length ? string.character(at: NSMaxRange(found)) : 0x20
            if found != selection, !Self.isWord(before), !Self.isWord(after) {
                path.addRoundedRect(in: rect(for: found, layout: layout), cornerWidth: Radius.glyph, cornerHeight: Radius.glyph)
            }
            search = NSRange(location: NSMaxRange(found), length: NSMaxRange(visible) - NSMaxRange(found))
        }
        return path
    }

    private func bracketPath(_ layout: NSLayoutManager) -> CGPath? {
        guard let (a, b) = bracketPair, max(a, b) < nsString.length else { return nil }
        let path = CGMutablePath()
        for index in [a, b] {
            let box = rect(for: NSRange(location: index, length: 1), layout: layout).insetBy(dx: Stroke.hairline / 2, dy: Stroke.hairline / 2)
            path.addRoundedRect(in: box, cornerWidth: Radius.glyph, cornerHeight: Radius.glyph)
        }
        return path
    }

    /// The bracket before or after the caret and its partner (within 20k characters).
    func findBracketPair() -> (Int, Int)? {
        let selection = selectedRange()
        guard selection.length == 0 else { return nil }
        let opens: [unichar: unichar] = [.parenOpen: .parenClose, .bracketOpen: .bracketClose, .braceOpen: .braceClose]
        let closes = Dictionary(uniqueKeysWithValues: opens.map { ($1, $0) })
        for index in [selection.location - 1, selection.location] {
            guard let c = char(at: index) else { continue }
            if let close = opens[c] {
                var depth = 0
                var i = index
                while i < min(nsString.length, index + 20_000) {
                    let d = nsString.character(at: i)
                    if d == c { depth += 1 } else if d == close {
                        depth -= 1
                        if depth == 0 { return (index, i) }
                    }
                    i += 1
                }
            } else if let open = closes[c] {
                var depth = 0
                var i = index
                while i >= max(0, index - 20_000) {
                    let d = nsString.character(at: i)
                    if d == c { depth += 1 } else if d == open {
                        depth -= 1
                        if depth == 0 { return (i, index) }
                    }
                    i -= 1
                }
            }
        }
        return nil
    }

    /// A resize can come inside the window's layout pass (a tab switch with the page zoomed),
    /// where laying out text for the decorations resizes this view again and AppKit throws.
    /// The caret's line takes the new width now; the rest follows on the next turn.
    private var decorationsPending = false

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !lineLayer.isHidden { lineLayer.frame.size.width = bounds.width }
        guard !decorationsPending else { return }
        decorationsPending = true
        DispatchQueue.main.async { [weak self] in
            self?.decorationsPending = false
            self?.updateDecorations()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        selectedTextAttributes[.backgroundColor] = NSColor(Theme.Editor.selection)
        DispatchQueue.main.async { [weak self] in self?.updateDecorations() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        selectedTextAttributes[.backgroundColor] = NSColor(Theme.Editor.selectionInactive)
        // The window's first responder changes after this returns.
        DispatchQueue.main.async { [weak self] in self?.updateDecorations() }
        return resigned
    }

    // MARK: Editing helpers

    /// Replaces text through the undo-aware path.
    private func replace(_ range: NSRange, with text: String, select: NSRange? = nil) {
        // Each command is its own undo step, not merged with the typing around it.
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        if let select { setSelectedRange(select) }
    }

    private func char(at index: Int) -> unichar? {
        index >= 0 && index < nsString.length ? nsString.character(at: index) : nil
    }

    /// The full lines the selection touches, with their newline.
    private var selectedLines: NSRange { nsString.lineRange(for: selectedRange()) }

    private func leadingWhitespace(of lineRange: NSRange) -> String {
        var end = lineRange.location
        while end < NSMaxRange(lineRange), let c = char(at: end), c == .space || c == .tab { end += 1 }
        return nsString.substring(with: NSRange(location: lineRange.location, length: end - lineRange.location))
    }

    private static let pairs: [unichar: unichar] = [.parenOpen: .parenClose, .bracketOpen: .bracketClose, .braceOpen: .braceClose]
    private static let quotes: Set<unichar> = [.quote, .apostrophe, .backtick]
    private static let closers: Set<unichar> = [.parenClose, .bracketClose, .braceClose]

    private var pairsEnabled: Bool { language.family == .code || language.family == .markup }

    // MARK: Typing

    override func insertText(_ insert: Any, replacementRange: NSRange) {
        guard let typed = (insert as? String) ?? (insert as? NSAttributedString)?.string, typed.utf16.count == 1,
            pairsEnabled, replacementRange.location == NSNotFound
        else { return super.insertText(insert, replacementRange: replacementRange) }
        let c = typed.utf16.first!
        let selection = selectedRange()
        let next = char(at: selection.location)
        // Typing the closer that's already there steps over it.
        if selection.length == 0, next == c, Self.closers.contains(c) || Self.quotes.contains(c) {
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return
        }
        let close = Self.pairs[c] ?? (Self.quotes.contains(c) ? c : nil)
        guard let close else { return super.insertText(insert, replacementRange: replacementRange) }
        let closeString = String(utf16CodeUnits: [close], count: 1)
        if selection.length > 0 {
            // Wraps the selection.
            let inner = nsString.substring(with: selection)
            replace(selection, with: typed + inner + closeString, select: NSRange(location: selection.location + 1, length: selection.length))
            return
        }
        let before = char(at: selection.location - 1)
        let nextOK = next == nil || next == .space || next == .tab || next == 0x0A || Self.closers.contains(next!)
            || next == .comma || next == .semicolon
        let quoteOK = !Self.quotes.contains(c) || before == nil || !(Self.isWord(before!) || before == c)
        if nextOK && quoteOK {
            replace(selection, with: typed + closeString, select: NSRange(location: selection.location + 1, length: 0))
        } else {
            super.insertText(insert, replacementRange: replacementRange)
        }
    }

    private static func isWord(_ c: unichar) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == .underscore || c > 0x7F
    }

    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        let lineRange = nsString.lineRange(for: NSRange(location: selection.location, length: 0))
        let indent = leadingWhitespace(of: lineRange)
        let before = char(at: selection.location - 1)
        let after = char(at: selection.location + selection.length)
        let opens = before.map { Self.pairs[$0] != nil || ($0 == .colon && language.id == "python") } ?? false
        if let before, let close = Self.pairs[before], after == close {
            // Between a pair: the caret goes on its own indented line, the closer below.
            let inner = "\n" + indent + indentUnit
            replace(selection, with: inner + "\n" + indent, select: NSRange(location: selection.location + (inner as NSString).length, length: 0))
        } else if opens {
            replace(selection, with: "\n" + indent + indentUnit)
        } else {
            replace(selection, with: "\n" + indent)
        }
    }

    override func insertTab(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length > 0, nsString.substring(with: selection).contains("\n") {
            shiftLines(right: true)
            return
        }
        let unit = indentUnit
        if unit == "\t" {
            replace(selection, with: "\t")
            return
        }
        // Spaces to the next tab stop.
        let lineStart = nsString.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let column = selection.location - lineStart
        let width = unit.count
        replace(selection, with: String(repeating: " ", count: width - column % width))
    }

    override func insertBacktab(_ sender: Any?) { shiftLines(right: false) }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0, selection.location > 0 else { return super.deleteBackward(sender) }
        let before = char(at: selection.location - 1)!
        let after = char(at: selection.location)
        if pairsEnabled, let after, Self.pairs[before] == after || (Self.quotes.contains(before) && before == after) {
            replace(NSRange(location: selection.location - 1, length: 2), with: "", select: NSRange(location: selection.location - 1, length: 0))
            return
        }
        // In leading spaces, back to the previous tab stop.
        let unit = indentUnit
        let lineStart = nsString.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let column = selection.location - lineStart
        if unit != "\t", column > 0,
            nsString.substring(with: NSRange(location: lineStart, length: column)).allSatisfy({ $0 == " " })
        {
            let back = column % unit.count == 0 ? unit.count : column % unit.count
            replace(NSRange(location: selection.location - back, length: back), with: "", select: NSRange(location: selection.location - back, length: 0))
            return
        }
        super.deleteBackward(sender)
    }

    // MARK: Lines

    func shiftLines(right: Bool) {
        let lines = selectedLines
        let text = nsString.substring(with: lines)
        let unit = indentUnit
        var parts = text.components(separatedBy: "\n")
        let trailing = text.hasSuffix("\n")
        if trailing { parts.removeLast() }
        parts = parts.map { line in
            if right { return line.isEmpty ? line : unit + line }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let spaces = line.prefix { $0 == " " }.count
            return String(line.dropFirst(min(spaces, unit == "\t" ? 4 : unit.count)))
        }
        let result = parts.joined(separator: "\n") + (trailing ? "\n" : "")
        replace(lines, with: result, select: NSRange(location: lines.location, length: (result as NSString).length - (trailing ? 1 : 0)))
    }

    func toggleComment() {
        let lines = selectedLines
        let text = nsString.substring(with: lines)
        let trailing = text.hasSuffix("\n")
        var parts = text.components(separatedBy: "\n")
        if trailing { parts.removeLast() }
        let result: [String]
        if let prefix = language.commentPrefix {
            let filled = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let commented = !filled.isEmpty && filled.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }
            let column = filled.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
            result = parts.map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                if commented {
                    guard let range = line.range(of: prefix) else { return line }
                    var removed = line
                    removed.removeSubrange(range)
                    if removed[range.lowerBound...].hasPrefix(" ") { removed.remove(at: range.lowerBound) }
                    return removed
                }
                let index = line.index(line.startIndex, offsetBy: column)
                return String(line[..<index]) + prefix + " " + String(line[index...])
            }
        } else if let (open, close) = language.blockComment {
            result = parts.map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return line }
                let indent = String(line.prefix { $0 == " " || $0 == "\t" })
                if trimmed.hasPrefix(open), trimmed.hasSuffix(close) {
                    let inner = trimmed.dropFirst(open.count).dropLast(close.count)
                    return indent + inner.trimmingCharacters(in: .whitespaces)
                }
                return indent + open + " " + trimmed + " " + close
            }
        } else {
            return
        }
        let joined = result.joined(separator: "\n") + (trailing ? "\n" : "")
        replace(lines, with: joined, select: NSRange(location: lines.location, length: (joined as NSString).length - (trailing ? 1 : 0)))
    }

    /// ⌥↑ / ⌥↓ moves the selected lines (the selection moves with them); with ⇧ it copies them.
    func moveLines(down: Bool, copy: Bool) {
        let selection = selectedRange()
        let before = nsString.length
        let start = selectedLines.location
        moveOrCopy(down: down, copy: copy)
        // Same place within the moved lines.
        let moved = selectedRange().location
        if moved != start || nsString.length != before {
            let offset = selection.location - start
            setSelectedRange(NSRange(location: min(moved + offset, nsString.length), length: selection.length))
        }
    }

    private func moveOrCopy(down: Bool, copy: Bool) {
        let lines = selectedLines
        let string = nsString
        var block = string.substring(with: lines)
        if !block.hasSuffix("\n") { block += "\n" }
        if copy {
            let insertAt = down ? NSMaxRange(lines) : lines.location
            let addition = string.substring(with: lines).hasSuffix("\n") ? block : "\n" + String(block.dropLast())
            let at = (down && !string.substring(with: lines).hasSuffix("\n")) ? NSMaxRange(lines) : insertAt
            let length = (addition as NSString).length
            replace(NSRange(location: at, length: 0), with: addition,
                    select: down ? NSRange(location: at + (addition.hasPrefix("\n") ? 1 : 0), length: (block as NSString).length - 1) : NSRange(location: lines.location, length: length - 1))
            return
        }
        if down {
            guard NSMaxRange(lines) < string.length else { return }
            let next = string.lineRange(for: NSRange(location: NSMaxRange(lines), length: 0))
            var other = string.substring(with: next)
            let union = NSUnionRange(lines, next)
            let endsWithNewline = other.hasSuffix("\n")
            if !endsWithNewline { other += "\n" }
            var result = other + block
            if !endsWithNewline { result.removeLast() }
            let start = lines.location + (other as NSString).length
            replace(union, with: result, select: NSRange(location: start, length: (block as NSString).length - 1))
        } else {
            guard lines.location > 0 else { return }
            let previous = string.lineRange(for: NSRange(location: lines.location - 1, length: 0))
            let other = string.substring(with: previous)
            let union = NSUnionRange(previous, lines)
            let endsWithNewline = string.substring(with: lines).hasSuffix("\n")
            var result = block + other
            if !endsWithNewline { result.removeLast() }
            replace(union, with: result, select: NSRange(location: previous.location, length: (block as NSString).length - 1))
        }
    }

    func deleteLines() {
        let lines = selectedLines
        var range = lines
        // The last line takes the newline before it instead.
        if NSMaxRange(lines) == nsString.length, !nsString.substring(with: lines).hasSuffix("\n"), lines.location > 0 {
            range = NSRange(location: lines.location - 1, length: lines.length + 1)
        }
        replace(range, with: "", select: NSRange(location: min(range.location, nsString.length - range.length), length: 0))
    }

    /// ⌘L: the caret's line, then each next line.
    func selectLine() {
        let selection = selectedRange()
        var lines = nsString.lineRange(for: selection)
        if selection == lines, NSMaxRange(lines) < nsString.length {
            lines = NSUnionRange(lines, nsString.lineRange(for: NSRange(location: NSMaxRange(lines), length: 0)))
        }
        setSelectedRange(lines)
    }

    // MARK: Keys

    private var finder: FindModel? { MainActor.assumeIsolated { controller?.find } }

    /// VS Code's editor keys, taken before anything else sees them: SwiftUI's host claims some
    /// ⌘ keys (⌘Z for its own undo) before an embedded view's key equivalents.
    nonisolated(unsafe) private static var keys: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MainActor.assumeIsolated { controller?.movedToWindow() }
        guard Self.keys == nil else { return }
        Self.keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let text = event.window?.firstResponder as? EditorTextView, text.shortcut(event) else { return event }
            return nil
        }
    }

    private func shortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        switch (flags, key, event.keyCode) {
        case (.command, "s", _): MainActor.assumeIsolated { _ = controller?.document.save() }
        case (.command, "z", _): undoManager?.undo()
        case ([.command, .shift], "z", _): undoManager?.redo()
        case (.command, "/", _): toggleComment()
        case ([.command, .option], _, 33): MainActor.assumeIsolated { controller?.foldAtCaret() }
        case ([.command, .option], _, 30): MainActor.assumeIsolated { controller?.unfoldAtCaret() }
        case (.command, "]", _): shiftLines(right: true)
        case (.command, "[", _): shiftLines(right: false)
        case (.command, "l", _): selectLine()
        case ([.command, .shift], "k", _): deleteLines()
        case (.command, "f", _): finder?.open(replace: false)
        case ([.command, .option], _, 3): finder?.open(replace: true)
        case (.command, "g", _): finder?.next()
        case ([.command, .shift], "g", _): finder?.previous()
        case (.command, "e", _): finder?.useSelection()
        case (.control, _, 5): MainActor.assumeIsolated { controller?.onGoToLine() }
        case (.option, _, 126): moveLines(down: false, copy: false)
        case (.option, _, 125): moveLines(down: true, copy: false)
        case ([.option, .shift], _, 126): moveLines(down: false, copy: true)
        case ([.option, .shift], _, 125): moveLines(down: true, copy: true)
        case (.option, _, 6):
            // ⌥Z: word wrap.
            MainActor.assumeIsolated { controller?.document.wrap.toggle() }
        default:
            return false
        }
        return true
    }

    // Edit ▸ Undo / Redo reach the first responder; this file's own history answers them.
    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return undoManager?.canUndo == true
        case #selector(redo(_:)): return undoManager?.canRedo == true
        default: return super.validateUserInterfaceItem(item)
        }
    }

}
