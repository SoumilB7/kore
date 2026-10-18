import AppKit
import Combine
import SwiftUI

/// The input box: attachments, text, and the bar of controls under it, with the slash menu
/// floating over the chat above it while a command is being typed. Files can be pasted (⌘V),
/// picked (+), or dropped onto the box. One box serves every chat tab: what it holds (draft,
/// files, mode, model) is the chat's, and what it keeps itself (caret, slash pick, undo) starts
/// over with another chat.
struct ComposerView: View {
    let chat: Chat
    var focused: FocusState<Bool>.Binding
    let openImage: (Attachment) -> Void
    @StateObject private var slashSelection = Local(0)
    @StateObject private var slashDismissed = Local(false)
    /// The window and the ⌘V monitor: kept for the monitor, never shown, so setting them as the
    /// composer appears doesn't draw it again.
    @StateObject private var window = Held<NSWindow?>(nil)
    @StateObject private var pasteMonitor = Held<Any?>(nil)
    /// The chat in the box now, for the monitor: it was made with the first one.
    @StateObject private var pasteChat = Held<Chat?>(nil)
    @StateObject private var dropTargeted = Local(false)
    /// The slash menu's frame while it shows, and the box's (global): a click outside both
    /// closes the menu. Kept for the click monitor, never shown.
    @StateObject private var menuFrame = Held<CGRect?>(nil)
    @StateObject private var boxFrame = Held<CGRect>(.zero)
    @StateObject private var clickMonitor = Held<Any?>(nil)
    /// Where the caret is, so Shift+Return can put a line break there: in that chat's draft.
    @StateObject private var caret = Local(Caret(chat: nil, selection: nil, text: nil, placed: false))

    /// A selection's indices are only good in the text they were made for: `text` is the draft
    /// when it was set. `placed`: Kore put it there, with the draft it had just set, so it's that
    /// text's for sure; the field's own can come a keystroke apart from its text.
    private struct Caret: Equatable {
        let chat: UUID?
        var selection: TextSelection?
        var text: String?
        var placed: Bool
    }

    /// The caret in this chat's draft; nil when it was placed in another chat's.
    private var selection: Binding<TextSelection?> {
        Binding(
            get: { caret.value.chat == chat.id ? caret.value.selection : nil },
            set: { caret.value = Caret(chat: chat.id, selection: $0, text: chat.draft, placed: false) })
    }

    /// Puts the caret at `offset` characters into the draft just set.
    private func place(at offset: Int) {
        let draft = chat.draft
        let index = draft.index(draft.startIndex, offsetBy: min(max(offset, 0), draft.count))
        caret.value = Caret(chat: chat.id, selection: TextSelection(insertionPoint: index), text: draft, placed: true)
    }

    /// Empty, except while a turn runs (look.md §10): a message sent then waits for it, or joins
    /// it where the CLI can steer (Codex).
    private var placeholder: String {
        // With a command and nothing typed: what the command takes ("objective").
        if let hint = chat.command?.hint, !hint.isEmpty, chat.draft.isEmpty { return hint }
        guard chat.status.isRunning else { return "" }
        return chat.provider == .codex ? "Add to this turn…" : "Queue another message…"
    }

    var body: some View {
        box
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { boxFrame.value = $0 }
            // The menu floats over the chat just above the box: the transcript keeps its height
            // and stays in view beside it.
            .overlay(alignment: .top) {
                let matches = slashMatches
                if !matches.isEmpty {
                    SlashMenu(
                        matches: matches, selected: min(slashSelection.value, matches.count - 1), current: chat.command?.name,
                        accept: accept)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { menuFrame.value = $0 }
                        .onDisappear { menuFrame.value = nil }
                        // Its bottom a gap above the box's top, its height its own.
                        .padding(.bottom, Space.lg)
                        .frame(height: 0, alignment: .bottom)  // lint:allow a zero-height anchor, not a size
                }
            }
        .background(WindowReader { window.value = $0 })
        .animation(Motion.fadeSlow, value: chat.controls.activeMode.id)
        .onAppear {
            pasteChat.value = chat
            pasteMonitor.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                removeCommand(event).flatMap(pasteAttachments)
            }
            clickMonitor.value = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { closeMenu(onClick: $0) }
        }
        .onDisappear {
            for monitor in [pasteMonitor.value, clickMonitor.value].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
            pasteMonitor.value = nil
            clickMonitor.value = nil
        }
        .onReceive(Self.undoChanges) { draftFromUndo($0) }
        .onChange(of: chat.id) {
            pasteChat.value = chat
            // The caret goes to the end of this chat's draft, ready to go on typing.
            place(at: chat.draft.count)
            slashSelection.value = 0
            slashDismissed.value = false
            forgetUndo()
        }
    }

    /// Every undo and redo in the app; `draftFromUndo` keeps the composer's.
    private static let undoChanges = NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)
        .merge(with: NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange))

    /// Undo and redo change the field's text without the text binding hearing of it, so the
    /// field and the draft would part: the draft takes the field's text back.
    private func draftFromUndo(_ note: Notification) {
        guard focused.wrappedValue, let editor = window.value?.firstResponder as? NSTextView, editor.isFieldEditor,
            let undo = note.object as? UndoManager, undo === editor.undoManager, editor.string != chat.draft
        else { return }
        chat.draft = editor.string
    }

    /// The field stays focused through a switch, and its undo was the last chat's typing: undone
    /// here, it would edit this chat's draft. The field editor keeps its own undo manager (not
    /// the window's, which the explorer's file moves use), so all of it goes.
    private func forgetUndo() {
        guard let editor = window.value?.firstResponder as? NSTextView, editor.isFieldEditor,
            let undo = editor.undoManager
        else { return }
        if undo === window.value?.undoManager { undo.removeAllActions(withTarget: editor) } else { undo.removeAllActions() }
        editor.breakUndoCoalescing()
    }

    private var box: some View {
        VStack(spacing: 0) {
            if dropTargeted.value {
                Text("Drop to attach")
                    .font(TextStyle.labelMedium)
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: Size.dropZone)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control)
                            .strokeBorder(
                                Theme.accentLine,
                                style: StrokeStyle(lineWidth: Stroke.hairline, dash: Size.dropDash)))
                    .padding(.horizontal, Space.xl)
                    .padding(.top, Space.lg)
            }
            if !chat.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.md) {
                        ForEach(chat.attachments) { attachment in
                            AttachmentChip(attachment: attachment, open: { openImage(attachment) }) {
                                chat.removeAttachment(attachment.id)
                            }
                        }
                    }
                    .padding(.horizontal, Space.xl)
                    .padding(.top, Space.lg)
                }
            }
            field
            Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
            ComposerBar(chat: chat, attach: attach, slash: openSlash)
        }
        .modeOutline(chat.controls.activeMode.rung, focused: focused.wrappedValue, highlighted: dropTargeted.value)
        // Only the box takes drops; the rest of the chat ignores them.
        .onDrop(of: [.fileURL, .image], isTargeted: Binding(get: { dropTargeted.value }, set: { dropTargeted.value = $0 })) { providers in
            Attachments.load(providers) { chat.attach($0) }
            focused.wrappedValue = true
            return true
        }
    }

    /// The command chip, then the text: one row, so the command reads as the message's start.
    private var field: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            if let command = chat.command {
                CommandChip(command: command, open: openSlash)
            }
            textField
        }
        .padding(Inset.field)
        // The field itself is one line tall; a click anywhere in the text area focuses it
        // at once rather than landing on padding.
        .contentShape(Rectangle())
        .onTapGesture { focused.wrappedValue = true }
    }

    private var textField: some View {
        TextField(placeholder, text: Binding(get: { chat.draft }, set: { chat.draft = $0 }), selection: selection, axis: .vertical)
            .textFieldStyle(.plain)
            .font(TextStyle.body)
            .foregroundStyle(Theme.text)
            .lineLimit(1...10)
            .storyID(StoryID.Composer.field)
            .focused(focused)
            .onSubmit { chat.send() }
            .onKeyPress(.upArrow) { moveSlash(-1) }
            .onKeyPress(.downArrow) { moveSlash(1) }
            .onKeyPress(.return, phases: .down) { press in
                // Shift+Return (and Option+Return) start a new line; Return sends.
                if !press.modifiers.isDisjoint(with: [.shift, .option]) {
                    insertLineBreak()
                    return .handled
                }
                return acceptSlash()
            }
            // Shift+Tab switches mode, as in both CLIs; plain Tab accepts a slash command.
            .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")]) { press in
                if press.key == KeyEquivalent("\u{19}") || press.modifiers.contains(.shift) {
                    chat.cycleMode()
                    return .handled
                }
                return acceptSlash()
            }
            .onKeyPress(.escape) {
                guard !slashMatches.isEmpty else { return .ignored }
                slashDismissed.value = true
                return .handled
            }
            .onChange(of: slashToken) { old, new in
                slashSelection.value = 0
                // Esc closes the menu for this "/word"; the next one opens it again.
                if new?.range.lowerBound != old?.range.lowerBound { slashDismissed.value = false }
            }
    }

    /// Replaces the selection (or inserts at the caret) with a line break, the caret after it.
    private func insertLineBreak() {
        var draft = chat.draft
        let range = selectedRange ?? draft.endIndex..<draft.endIndex
        let offset = draft.distance(from: draft.startIndex, to: range.lowerBound)
        draft.replaceSubrange(range, with: "\n")
        chat.draft = draft
        place(at: offset + 1)
    }

    // MARK: Paste and +

    /// ⌘V in this chat's composer with files or an image on the clipboard attaches them;
    /// anything else (text) pastes normally.
    private func pasteAttachments(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers == "v",
            let window = window.value, event.window === window, focused.wrappedValue, let chat = pasteChat.value,
            let urls = Attachments.fromPasteboard(.general)
        else { return event }
        chat.attach(urls)
        return nil
    }

    /// Backspace with the caret before the first character takes the command chip off; the
    /// text stays. (The field's own key handling never shows SwiftUI that key.)
    private func removeCommand(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == Self.backspaceKey,
            event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
            let window = window.value, event.window === window, focused.wrappedValue,
            let chat = pasteChat.value, chat.command != nil,
            let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, !editor.hasMarkedText(),
            editor.selectedRange() == NSRange(location: 0, length: 0)
        else { return event }
        chat.command = nil
        return nil
    }

    private static let backspaceKey: UInt16 = 51

    private func attach() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = chat.folder
        if panel.runModal() == .OK { chat.attach(panel.urls) }
        focused.wrappedValue = true
    }

    // MARK: Slash commands

    /// What's selected in this chat's draft (empty: the caret), read from the editor while it
    /// shows this draft (moving the caret alone, by ⌘← or a click, doesn't reach the selection
    /// binding), else a caret Kore placed in this very text; nil when not known. The field's own
    /// selection is never carried into the draft: it can belong to the text a keystroke ahead,
    /// and an index of one string used in another traps.
    private var selectedRange: Range<String.Index>? {
        let draft = chat.draft
        let editor = fieldEditor
        if let editor, editor.string == draft { return Range(editor.selectedRange(), in: draft) }
        let kept = caret.value
        guard kept.chat == chat.id, kept.placed, kept.text == draft,
            case .selection(let range) = kept.selection?.indices,
            let lower = String.Index(range.lowerBound, within: draft), let upper = String.Index(range.upperBound, within: draft)
        else { return nil }
        return lower..<upper
    }

    /// Where the caret is in this chat's draft: the end when it isn't known, nil with a range
    /// selected.
    private var caretIndex: String.Index? {
        guard let range = selectedRange else { return chat.draft.endIndex }
        return range.isEmpty ? range.lowerBound : nil
    }

    /// The "/word" at the caret (or Codex's "$word"), anywhere in the draft.
    private var slashToken: SlashToken? {
        guard let caret = caretIndex else { return nil }
        return SlashToken(in: chat.draft, caret: caret, skills: chat.provider == .codex)
    }

    private var slashMatches: [SlashCommand] {
        guard !slashDismissed.value, let token = slashToken else { return [] }
        let commands = token.sigil == "$" ? chat.controls.commands.filter { $0.kind == .skill } : chat.controls.commands
        let query = token.query
        // Foundation's `contains("")` is false, so a bare "/" must list everything explicitly.
        if query.isEmpty { return commands }
        let hits = commands.filter { $0.name.lowercased().contains(query) }
        return hits.filter { $0.name.lowercased().hasPrefix(query) } + hits.filter { !$0.name.lowercased().hasPrefix(query) }
    }

    /// The field's editor while the field has focus.
    private var fieldEditor: NSTextView? {
        guard focused.wrappedValue, let editor = window.value?.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
        return editor
    }

    /// An input method is composing (marked text): its keys are its own.
    private var composing: Bool { fieldEditor?.hasMarkedText() ?? false }

    private func moveSlash(_ delta: Int) -> KeyPress.Result {
        let count = slashMatches.count
        guard count > 0, !composing else { return .ignored }
        slashSelection.value = min(max(slashSelection.value + delta, 0), count - 1)
        return .handled
    }

    private func acceptSlash() -> KeyPress.Result {
        let matches = slashMatches
        guard !matches.isEmpty, !composing else { return .ignored }
        accept(matches[min(slashSelection.value, matches.count - 1)])
        return .handled
    }

    /// The `/` key (and the chip): a "/" at the caret, as if typed, so the menu opens there.
    /// A space goes before it when the caret ends a word; in a "/word" already, the menu opens
    /// again for it.
    private func openSlash() {
        slashDismissed.value = false
        focused.wrappedValue = true
        if slashToken != nil { return }
        var draft = chat.draft
        let range = selectedRange ?? draft.endIndex..<draft.endIndex
        let spaced = range.lowerBound > draft.startIndex && !draft[draft.index(before: range.lowerBound)].isWhitespace
        let offset = draft.distance(from: draft.startIndex, to: range.lowerBound) + (spaced ? 2 : 1)
        draft.replaceSubrange(range, with: spaced ? " /" : "/")
        chat.draft = draft
        place(at: offset)
    }

    /// A pick replaces the "/word" it was filtered by: a command goes to the chip (one per
    /// message, so it replaces any there), a Codex skill in the text as "$name ". The caret
    /// stays where the word was, and the field's undo starts over, as its text was set.
    private func accept(_ command: SlashCommand) {
        let insertion = command.kind == .skill ? command.insertion : ""
        let (draft, caret) = slashToken.map { $0.replacing(in: chat.draft, with: insertion) } ?? (chat.draft, chat.draft.count)
        if command.kind != .skill { chat.command = command }
        chat.draft = draft
        place(at: caret)
        slashDismissed.value = false
        focused.wrappedValue = true
        forgetUndo()
    }

    /// A click outside the menu and the box closes the menu; the click goes on as it was.
    private func closeMenu(onClick event: NSEvent) -> NSEvent? {
        guard let menu = menuFrame.value, let window = window.value, event.window === window, let content = window.contentView
        else { return event }
        // Window coordinates (bottom-left) to SwiftUI's global ones (top-left).
        let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        if !menu.contains(point), !boxFrame.value.contains(point) { slashDismissed.value = true }
        return event
    }
}
