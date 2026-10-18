import AppKit

/// Code folding, as in VS Code: regions by indentation (`FoldRegions`), folded and unfolded from
/// the gutter's chevrons, ⌥⌘[ / ⌥⌘] at the caret, or the " ⋯ " chip. A folded range keeps its
/// text: its glyphs are null and its line breaks don't break lines, so the lines under the
/// fold's first line take no room. Undo, copy, find and save see the whole text.
extension CodeEditorController: @preconcurrency NSLayoutManagerDelegate {
    // MARK: Layout

    func layoutManager(
        _ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>, font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        let count = glyphRange.length
        guard count > 0, !folds.isEmpty else { return 0 }
        let span = NSRange(location: characterIndexes[0], length: characterIndexes[count - 1] - characterIndexes[0] + 1)
        guard folds.contains(where: { NSIntersectionRange($0, span).length > 0 }) else { return 0 }
        var hidden = Array(UnsafeBufferPointer(start: properties, count: count))
        for i in 0..<count where fold(containing: characterIndexes[i]) != nil { hidden[i] = .null }
        layoutManager.setGlyphs(glyphs, properties: hidden, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return count
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        fold(containing: charIndex) != nil ? .zeroAdvancement : action
    }

    // MARK: Looking up

    /// The fold whose text holds the character at `index`.
    func fold(containing index: Int) -> NSRange? {
        var low = 0
        var high = folds.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let fold = folds[mid]
            if index < fold.location { high = mid - 1 } else if index >= NSMaxRange(fold) { low = mid + 1 } else { return fold }
        }
        return nil
    }

    /// The fold that hides `line` (a line under a fold's first one).
    func hiddenFold(line: Int) -> NSRange? {
        guard !folds.isEmpty, line > 0 else { return nil }
        let start = lines.start(of: line)
        // The line starts just after a break inside the fold.
        return fold(containing: start - 1).flatMap { start <= NSMaxRange($0) ? $0 : nil }
    }

    /// The fold that starts at the end of `line`.
    func fold(startingOn line: Int) -> NSRange? {
        let end = NSMaxRange(lines.range(of: line, in: document.storage.string as NSString))
        return fold(containing: end).flatMap { $0.location == end ? $0 : nil }
    }

    // MARK: Folding

    func toggleFold(line: Int) {
        if let fold = fold(startingOn: line) { unfold(fold) } else { fold(line: line) }
    }

    func fold(line: Int) {
        guard let end = regions.end(of: line) else { return }
        let string = document.storage.string as NSString
        let from = NSMaxRange(lines.range(of: line, in: string))
        let to = NSMaxRange(lines.range(of: end, in: string))
        guard to > from else { return }
        let range = NSRange(location: from, length: to - from)
        // Folds inside it go with it; VS Code keeps them, but they'd be hidden anyway.
        folds.removeAll { NSIntersectionRange($0, range) == $0 }
        folds.append(range)
        folds.sort { $0.location < $1.location }
        // The caret can't stay out of sight: it goes to the fold's first line.
        let selection = textView.selectedRange()
        if fold(containing: selection.location) != nil || (selection.location == NSMaxRange(range) && selection.location > from) {
            textView.setSelectedRange(NSRange(location: from, length: 0))
        }
        relayout(range)
    }

    func unfold(_ range: NSRange) {
        folds.removeAll { $0 == range }
        relayout(range)
    }

    /// ⌥⌘[: the innermost unfolded region at the caret.
    func foldAtCaret() {
        let line = lines.line(at: textView.selectedRange().location)
        if let region = regions.containing(line).first(where: { fold(startingOn: $0.start) == nil }) {
            fold(line: region.start)
        }
    }

    /// ⌥⌘]: the fold on the caret's line.
    func unfoldAtCaret() {
        let caret = textView.selectedRange().location
        if let fold = fold(startingOn: lines.line(at: caret)) ?? fold(containing: caret) { unfold(fold) }
    }

    /// A selection that lands inside a fold (find, go to line, a click on a chip) opens it.
    func revealSelection() {
        guard !folds.isEmpty else { return }
        let selection = textView.selectedRange()
        for index in [selection.location, NSMaxRange(selection)] {
            // The first position, at the end of the fold's first line, is in sight.
            if let fold = fold(containing: index - 1), index > fold.location { unfold(fold) }
        }
    }

    private func relayout(_ range: NSRange) {
        guard let layout = textView.layoutManager else { return }
        let safe = NSIntersectionRange(range, NSRange(location: 0, length: document.storage.length))
        layout.invalidateGlyphs(forCharacterRange: safe, changeInLength: 0, actualCharacterRange: nil)
        layout.invalidateLayout(forCharacterRange: safe, actualCharacterRange: nil)
        textView.needsDisplay = true
        recolor(force: true)
        textView.updateDecorations()
        gutterNeedsDisplay()
    }

    // MARK: Edits

    /// Folds before the edit move with it, folds it touches open, and the rest stay.
    func foldsEdited(_ edited: NSRange, delta: Int) {
        guard !folds.isEmpty else { return }
        let old = NSRange(location: edited.location, length: edited.length - delta)
        var opened: [NSRange] = []
        folds = folds.compactMap { fold in
            if NSMaxRange(old) <= fold.location { return NSRange(location: fold.location + delta, length: fold.length) }
            if old.location >= NSMaxRange(fold) { return fold }
            opened.append(NSRange(location: fold.location, length: max(0, fold.length + delta)))
            return nil
        }
        guard !opened.isEmpty else { return }
        // Glyphs can't be redone while the storage is mid-edit.
        DispatchQueue.main.async { [weak self] in opened.forEach { self?.relayout($0) } }
    }

    /// Regions follow the text at idle; one keystroke doesn't re-scan a long file.
    func scheduleRegions() {
        regionsPending?.cancel()
        regionsPending = Task { [weak self] in
            try? await Task.sleep(for: Size.Editor.foldIdle)
            guard !Task.isCancelled, let self else { return }
            self.computeRegions()
            self.gutterNeedsDisplay()
        }
    }

    func computeRegions() {
        let width = max(1, document.indent.width)
        regions = FoldRegions.compute(document.storage.string as NSString, lines: lines, tabWidth: width)
    }
}
