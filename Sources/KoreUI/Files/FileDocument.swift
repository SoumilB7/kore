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
        /// Automatic saves never open a modal alert; edits stay in the document.
        case saveFailed(String)
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
    /// Exact source bytes catch external edits even when size and modification date match.
    @ObservationIgnored private var savedBytes: Data?
    @ObservationIgnored private var savedLineEnding = TextFile.LineEnding.lf
    @ObservationIgnored private let autoSave: FileAutoSave
    @ObservationIgnored private var autoSaveTask: Task<Void, Never>?
    @ObservationIgnored private var autoSaveGeneration = 0
    @ObservationIgnored private var closed = false
    @ObservationIgnored lazy var editor = CodeEditorController(document: self)

    let id = UUID()
    var name: String { url.lastPathComponent }

    init(url: URL, autoSave: FileAutoSave = .shared) {
        self.autoSave = autoSave
        // The real path, as the watcher, the tree and other tabs see it.
        let url = URL(fileURLWithPath: realPath(url.path))
        self.url = url
        let language = Language.of(url)
        self.language = language
        wrap = Self.wraps(language)
        diskStamp = TextFile.Stamp.of(url)
        autoSave.register(self)
    }

    private func sourceBytesForLoading() -> Data? {
        guard let size = TextFile.Stamp.of(url)?.size, size <= TextFile.editLimit else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func wraps(_ language: Language) -> Bool {
        language.id == "markdown" || language.id == "plaintext"
    }

    // MARK: - Loading and saving

    /// The file was renamed or moved in the explorer; the text and edits stay.
    func moved(to url: URL) {
        cancelAutoSave()
        self.url = url
        // A rename changes the path, not the source the edits were based on.
        if let savedBytes, let bytes = try? Data(contentsOf: url), bytes == savedBytes {
            file.stamp = TextFile.Stamp.of(url)
            diskStamp = file.stamp
        }
        let language = Language.of(url)
        if language != self.language {
            self.language = language
            editor.setLanguage(language)
        }
        scheduleAutoSave()
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        load()
    }

    func load() {
        cancelAutoSave()
        loaded = true
        savedBytes = sourceBytesForLoading()
        file = TextFile.read(url)
        diskStamp = file.stamp
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
        savedLineEnding = file.lineEnding
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
        cancelAutoSave()
        return write(automatically: false)
    }

    private func write(automatically: Bool) -> Bool {
        guard isText, !readOnly else { return false }
        let text = storage.string
        do {
            file.stamp = try file.write(text, to: url)
        } catch {
            if automatically { autoSaveFailed(error.localizedDescription) }
            else { NSAlert(error: error).runModal() }
            return false
        }
        saved = text
        savedLineEnding = file.lineEnding
        savedBytes = try? Data(contentsOf: url)
        diskStamp = file.stamp
        isDirty = false
        notice = nil
        editor.refreshChanges()
        if automatically { UILog.event("file-auto-save", ["id": id.uuidString, "result": "saved"]) }
        return true
    }

    /// Called by the editor after each edit.
    func edited() {
        // Retry a failed automatic save only after another edit, never on an idle timer.
        if case .saveFailed = notice { notice = nil }
        // Back to the saved text by undo is clean again; format changes remain unsaved.
        let dirty = file.lineEnding != savedLineEnding || storage.length != (saved as NSString).length || storage.string != saved
        if dirty != isDirty { isDirty = dirty }
        scheduleAutoSave()
    }

    // MARK: - Automatic saving

    func autoSaveChanged() { scheduleAutoSave() }

    private func cancelAutoSave() {
        autoSaveGeneration &+= 1
        autoSaveTask?.cancel()
        autoSaveTask = nil
    }

    private func scheduleAutoSave() {
        cancelAutoSave()
        guard autoSave.isEnabled, !closed, loaded, isText, !readOnly, isDirty, notice == nil else { return }
        let generation = autoSaveGeneration
        let delay = autoSave.delay
        let pause = autoSave.pause
        autoSaveTask = Task { [weak self] in
            do { try await pause(delay) } catch { return }
            guard let self, !Task.isCancelled, self.autoSaveGeneration == generation else { return }
            self.autoSaveTask = nil
            self.saveAutomatically()
        }
    }

    /// Before a close prompt, finish a safe pending save. Conflicts/errors stay dirty so the
    /// existing Save/Discard/Cancel question can decide what happens to those edits.
    @discardableResult func flushAutoSave() -> Bool {
        cancelAutoSave()
        return !isDirty || saveAutomatically()
    }

    /// A confirmed close/discard must not leave a delayed write behind.
    func closeAutoSave() {
        closed = true
        cancelAutoSave()
    }

    /// A reopened tab can keep its document, undo, and caret without keeping a stale task.
    func resumeAutoSave() {
        closed = false
        scheduleAutoSave()
    }

    private func autoSaveFailed(_ reason: String) {
        notice = .saveFailed(reason)
        UILog.event("file-auto-save", ["id": id.uuidString, "result": "failed"])
    }

    @discardableResult private func saveAutomatically() -> Bool {
        guard autoSave.isEnabled, !closed, loaded, isText, !readOnly, isDirty, notice == nil else { return false }
        guard let stamp = TextFile.Stamp.of(url) else {
            if FileManager.default.fileExists(atPath: path) { autoSaveFailed("Kore can't read this file.") }
            else {
                notice = .deleted
                UILog.event("file-auto-save", ["id": id.uuidString, "result": "deleted"])
            }
            return false
        }
        guard stamp == file.stamp else {
            notice = .changed
            UILog.event("file-auto-save", ["id": id.uuidString, "result": "changed"])
            return false
        }
        guard FileManager.default.isWritableFile(atPath: path) else {
            autoSaveFailed("This file is read-only. Your edits aren't saved.")
            return false
        }
        guard let bytes = try? Data(contentsOf: url), let savedBytes else {
            autoSaveFailed("Kore can't read this file. Your edits aren't saved.")
            return false
        }
        guard bytes == savedBytes else {
            notice = .changed
            UILog.event("file-auto-save", ["id": id.uuidString, "result": "changed"])
            return false
        }
        return write(automatically: true)
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
            cancelAutoSave()
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
            cancelAutoSave()
            return
        }
        reloadInPlace()
    }

    /// Replaces only what changed, so the caret and scroll stay, and remembers the changed
    /// lines for the flash.
    func reloadInPlace() {
        cancelAutoSave()
        savedBytes = sourceBytesForLoading()
        let next = TextFile.read(url)
        guard case .text(let text) = next.content else {
            file = next
            return
        }
        file = next
        diskStamp = next.stamp
        savedLineEnding = next.lineEnding
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
        diskStamp = file.stamp
        savedBytes = try? Data(contentsOf: url)
        notice = nil
        scheduleAutoSave()
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
        if case .saveFailed = notice { notice = nil }
        isDirty = ending != savedLineEnding || storage.string != saved
        scheduleAutoSave()
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
