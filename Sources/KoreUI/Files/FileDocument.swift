import AppKit
import KoreCore
import Observation

/// A file open in a tab: its text (in the editor's own storage, so switching tabs keeps the
/// text, caret, scroll and undo), whether it has unsaved edits, and how it differs from the
/// disk. Loaded when its tab first shows.
@MainActor @Observable
final class FileDocument: Identifiable {
    enum Notice: Equatable {
        case deleted
        /// Changed on disk while there are unsaved edits.
        case changed
    }

    private(set) var url: URL
    var path: String { url.path }
    private(set) var file = TextFile(content: .missing)
    private(set) var loaded = false
    private(set) var isDirty = false
    private(set) var notice: Notice?
    /// Opened past the size limit: plain text, read-only.
    private(set) var readOnly = false
    var language: Language
    var wrap: Bool
    /// For the status row.
    var caret = Caret()

    struct Caret: Equatable {
        var line = 1
        var column = 1
        var selected = 0
    }

    /// A place in the file: a 1-based line and a UTF-16 column range in it.
    struct Place: Equatable {
        let line: Int
        let columns: Range<Int>
    }

    /// Selected once the editor shows the text (a search hit opened before the file loaded).
    @ObservationIgnored var pendingPlace: Place?

    /// Selects `place` in the editor, now if it's showing, else when it does.
    func reveal(_ place: Place) {
        pendingPlace = place
        // A match is shown in the text, not a renderer's view of it.
        showsRaw = true
        if loaded, isText { editor.applyPendingPlace() }
    }

    /// Lines the last reload from disk changed (UTF-16 ranges), for the editor's flash.
    @ObservationIgnored var reloadedRanges: [NSRange] = []
    /// Bumped when the text is replaced from disk, so the editor recolours, and on any other
    /// change on disk, so a renderer reloads (its text may never have been loaded).
    private(set) var revision = 0
    /// The disk's stamp as last seen, to tell a real change from an event that changed nothing.
    @ObservationIgnored private var diskStamp: TextFile.Stamp?
    /// The renderer for this file, and the tab's raw ⇄ rendered choice.
    let rendering = FileRendering()
    /// The tab shows the editor although a renderer matches (rendered comes first).
    var showsRaw: Bool {
        get { rendering.showsRaw }
        set { rendering.showsRaw = newValue }
    }

    @ObservationIgnored let storage = NSTextStorage()
    @ObservationIgnored private var saved = ""
    @ObservationIgnored lazy var editor = CodeEditorController(document: self)

    let id = UUID()
    var name: String { url.lastPathComponent }

    init(url: URL) {
        // The real path, as the watcher, the tree and other tabs see it.
        let url = URL(fileURLWithPath: realPath(url.path))
        self.url = url
        let language = Language.of(url)
        self.language = language
        wrap = Self.wraps(language)
        diskStamp = TextFile.Stamp.of(url)
    }

    private static func wraps(_ language: Language) -> Bool {
        language.id == "markdown" || language.id == "plaintext"
    }

    // MARK: - Loading and saving

    /// The file was renamed or moved in the explorer; the text and edits stay.
    func moved(to url: URL) {
        self.url = url
        let language = Language.of(url)
        if language != self.language {
            self.language = language
            editor.setLanguage(language)
        }
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        load()
    }

    func load() {
        loaded = true
        file = TextFile.read(url)
        notice = nil
        if case .text(let text) = file.content {
            setText(text)
        }
    }

    /// Opens a file over the size limit as plain, read-only text.
    func openAnyway() {
        guard case .tooLarge = file.content, let data = try? Data(contentsOf: url) else { return }
        readOnly = true
        language = .plain
        wrap = false
        file.content = .text(String(decoding: data, as: UTF8.self))
        if case .text(let text) = file.content { setText(text) }
    }

    private func setText(_ text: String) {
        saved = text
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        storage.endEditing()
        isDirty = false
        revision += 1
        editor.textReplaced()
    }

    var isText: Bool {
        if case .text = file.content { return true }
        return false
    }

    @discardableResult
    func save() -> Bool {
        guard isText, !readOnly else { return false }
        let text = storage.string
        do {
            file.stamp = try file.write(text, to: url)
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
        saved = text
        isDirty = false
        notice = nil
        editor.refreshChanges()
        return true
    }

    /// Called by the editor after each edit.
    func edited() {
        // Back to the saved text by undo is clean again; compare only when the length matches.
        let dirty = storage.length != (saved as NSString).length || storage.string != saved
        if dirty != isDirty { isDirty = dirty }
    }

    // MARK: - The disk

    /// Something under this path changed on disk: reload in place when there are no unsaved
    /// edits, else say so. Our own saves don't count.
    func diskChanged() {
        let stamp = TextFile.Stamp.of(url)
        if stamp != diskStamp {
            diskStamp = stamp
            // Editor text reloading in place bumps it itself.
            if !loaded || !isText || readOnly { revision += 1 }
        }
        guard loaded else { return }
        guard let stamp else {
            if !FileManager.default.fileExists(atPath: path) { notice = .deleted }
            return
        }
        if notice == .deleted { notice = nil }
        guard stamp != file.stamp else { return }
        guard isText, !readOnly else {
            load()
            return
        }
        if isDirty {
            notice = .changed
            return
        }
        reloadInPlace()
    }

    /// Replaces only what changed, so the caret and scroll stay, and remembers the changed
    /// lines for the flash.
    func reloadInPlace() {
        let next = TextFile.read(url)
        guard case .text(let text) = next.content else {
            file = next
            return
        }
        file = next
        let old = storage.string as NSString
        let new = text as NSString
        let prefix = Self.commonPrefix(old, new)
        let suffix = Self.commonSuffix(old, new, limit: min(old.length, new.length) - prefix)
        let replaced = NSRange(location: prefix, length: old.length - prefix - suffix)
        let inserted = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        saved = text
        if replaced.length > 0 || !inserted.isEmpty {
            reloadedRanges = [NSRange(location: prefix, length: (inserted as NSString).length)]
            editor.replaceFromDisk(replaced, with: inserted)
        }
        isDirty = false
        notice = nil
        revision += 1
    }

    /// The disk against the unsaved edits, for the changes modal.
    func compare() async -> FileChange? {
        guard case .text(let disk) = TextFile.read(url).content else { return nil }
        return await UnifiedDiff.compare(old: disk, new: storage.string, path: path)
    }

    /// Keeps the edits; the next save overwrites the disk.
    func keepMine() {
        file.stamp = TextFile.Stamp.of(url)
        notice = nil
    }

    private static func commonPrefix(_ a: NSString, _ b: NSString) -> Int {
        let n = min(a.length, b.length)
        var i = 0
        while i < n, a.character(at: i) == b.character(at: i) { i += 1 }
        return i
    }

    private static func commonSuffix(_ a: NSString, _ b: NSString, limit: Int) -> Int {
        var i = 0
        while i < limit, a.character(at: a.length - 1 - i) == b.character(at: b.length - 1 - i) { i += 1 }
        return i
    }

    // MARK: - Status

    var indent: TextFile.Indent { file.indent }

    func setIndent(_ indent: TextFile.Indent) { file.indent = indent }

    /// VS Code's "Convert Indentation": every line's leading whitespace rewritten as tabs or as
    /// spaces of the current width (4 when the file uses tabs), keeping each line's column. One
    /// edit, so one undo; nothing else on a line changes.
    func convertIndentation(toTabs: Bool) {
        guard isText, !readOnly else { return }
        let width = if case .spaces(let n) = file.indent { n } else { 4 }
        let old = storage.string as NSString
        let new = Self.reindent(storage.string, width: width, toTabs: toTabs) as NSString
        file.indent = toTabs ? .tabs : .spaces(width)
        guard !old.isEqual(to: new as String) else { return }
        let prefix = Self.commonPrefix(old, new)
        let suffix = Self.commonSuffix(old, new, limit: min(old.length, new.length) - prefix)
        let range = NSRange(location: prefix, length: old.length - prefix - suffix)
        let inserted = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        let text = editor.textView
        guard text.shouldChangeText(in: range, replacementString: inserted) else { return }
        text.textStorage?.replaceCharacters(in: range, with: inserted)
        text.didChangeText()
    }

    /// Leading tabs and spaces as columns (a tab to the next multiple of `width`), then written
    /// back as tabs (and spaces for a remainder) or as spaces. Lines are what NSString counts as
    /// lines (`\n`, `\r\n`, a lone `\r`, U+2028), each kept with its own ending; a last line
    /// with no ending stays without one.
    static func reindent(_ text: String, width: Int, toTabs: Bool) -> String {
        let string = text as NSString
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var start = 0
        while start < string.length {
            var lineEnd = 0
            var contentsEnd = 0
            string.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            var column = 0
            var indentEnd = start
            while indentEnd < contentsEnd {
                let c = string.character(at: indentEnd)
                guard c == 0x20 || c == 0x09 else { break }
                column = c == 0x09 ? (column / width + 1) * width : column + 1
                indentEnd += 1
            }
            // A blank line, or one with no indentation, keeps what it had.
            if indentEnd == contentsEnd || column == 0 {
                out += string.substring(with: NSRange(location: start, length: lineEnd - start))
            } else {
                out += toTabs
                    ? String(repeating: "\t", count: column / width) + String(repeating: " ", count: column % width)
                    : String(repeating: " ", count: column)
                out += string.substring(with: NSRange(location: indentEnd, length: lineEnd - indentEnd))
            }
            start = lineEnd
        }
        return out
    }

    var lineEnding: TextFile.LineEnding { file.lineEnding }

    func setLineEnding(_ ending: TextFile.LineEnding) {
        guard ending != file.lineEnding else { return }
        file.lineEnding = ending
        isDirty = true
    }

    var encodingName: String {
        switch file.encoding {
        case .utf8: file.hasBOM ? "UTF-8 with BOM" : "UTF-8"
        case .utf16: "UTF-16"
        case .isoLatin1: "Western (ISO 8859-1)"
        default: "Unknown"
        }
    }
}
