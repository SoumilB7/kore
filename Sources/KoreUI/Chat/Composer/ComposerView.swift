import AppKit
import SwiftUI

/// The input box: attachments, text, and the bar of controls under it, with the slash menu
/// above it while a command is being typed. Files can be pasted (⌘V), picked (+), or dropped
/// onto the box. One box serves every chat tab: what it holds (draft, files, mode, model) is
/// the chat's, and what it keeps itself (caret, slash pick, undo) starts over with another chat.
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
    @StateObject private var dropTargeted = Local(false)
    /// Where the caret is, so Shift+Return can put a line break there: in that chat's draft.
    @StateObject private var caret = Local(Caret(chat: nil, selection: nil))

    private struct Caret: Equatable {
        let chat: UUID?
        var selection: TextSelection?
    }

    /// The caret in this chat's draft; nil when it was placed in another chat's.
    private var selection: Binding<TextSelection?> {
        Binding(
            get: { caret.value.chat == chat.id ? caret.value.selection : nil },
            set: { caret.value = Caret(chat: chat.id, selection: $0) })
    }

    /// Empty, except while a turn runs (look.md §10): a message sent then waits for it, or joins
    /// it where the CLI can steer (Codex).
    private var placeholder: String {
        guard chat.status.isRunning else { return "" }
        return chat.provider == .codex ? "Add to this turn…" : "Queue another message…"
    }

    var body: some View {
        VStack(spacing: Space.lg) {
            if !slashMatches.isEmpty {
                SlashMenu(matches: slashMatches, selected: min(slashSelection.value, slashMatches.count - 1), accept: accept)
            }
            box
        }
        .background(WindowReader { window.value = $0 })
        .animation(Motion.fadeSlow, value: chat.controls.activeMode.id)
        .onAppear {
            pasteMonitor.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { pasteAttachments($0) }
        }
        .onDisappear {
            if let monitor = pasteMonitor.value { NSEvent.removeMonitor(monitor) }
            pasteMonitor.value = nil
        }
        .onChange(of: chat.id) {
            // The caret goes to the end of this chat's draft, ready to go on typing.
            caret.value = Caret(chat: chat.id, selection: TextSelection(insertionPoint: chat.draft.endIndex))
            slashSelection.value = 0
            slashDismissed.value = false
            forgetUndo()
        }
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
            ComposerBar(chat: chat, attach: attach) {
                if chat.draft.isEmpty { chat.draft = "/" }
                focused.wrappedValue = true
            }
        }
        .modeOutline(chat.controls.activeMode.rung, focused: focused.wrappedValue, highlighted: dropTargeted.value)
        // Only the box takes drops; the rest of the chat ignores them.
        .onDrop(of: [.fileURL, .image], isTargeted: Binding(get: { dropTargeted.value }, set: { dropTargeted.value = $0 })) { providers in
            Attachments.load(providers) { chat.attach($0) }
            focused.wrappedValue = true
            return true
        }
    }

    private var field: some View {
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
            .onChange(of: chat.draft) {
                if !chat.draft.hasPrefix("/") { slashDismissed.value = false }
            }
            .onChange(of: slashQuery) { slashSelection.value = 0 }
            .padding(Inset.field)
            // The field itself is one line tall; a click anywhere in the text area focuses it
            // at once rather than landing on padding.
            .contentShape(Rectangle())
            .onTapGesture { focused.wrappedValue = true }
    }

    /// Replaces the selection (or inserts at the caret) with a line break, the caret after it.
    private func insertLineBreak() {
        var draft = chat.draft
        var range = draft.endIndex..<draft.endIndex
        if case .selection(let selected) = selection.wrappedValue?.indices,
            selected.lowerBound >= draft.startIndex, selected.upperBound <= draft.endIndex
        {
            range = selected
        }
        let offset = draft.distance(from: draft.startIndex, to: range.lowerBound)
        draft.replaceSubrange(range, with: "\n")
        chat.draft = draft
        selection.wrappedValue = TextSelection(insertionPoint: draft.index(draft.startIndex, offsetBy: offset + 1))
    }

    // MARK: Paste and +

    /// ⌘V in this chat's composer with files or an image on the clipboard attaches them;
    /// anything else (text) pastes normally.
    private func pasteAttachments(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers == "v",
            let window = window.value, event.window === window, focused.wrappedValue,
            let urls = Attachments.fromPasteboard(.general)
        else { return event }
        chat.attach(urls)
        return nil
    }

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

    /// The text after a leading "/" while the draft is still a single word.
    private var slashQuery: String? {
        let draft = chat.draft
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        return String(draft.dropFirst()).lowercased()
    }

    private var slashMatches: [SlashCommand] {
        guard !slashDismissed.value, let query = slashQuery else { return [] }
        // Foundation's `contains("")` is false, so a bare "/" must list everything explicitly.
        if query.isEmpty { return chat.controls.commands }
        let hits = chat.controls.commands.filter { $0.name.lowercased().contains(query) }
        return hits.filter { $0.name.lowercased().hasPrefix(query) } + hits.filter { !$0.name.lowercased().hasPrefix(query) }
    }

    private func moveSlash(_ delta: Int) -> KeyPress.Result {
        let count = slashMatches.count
        guard count > 0 else { return .ignored }
        slashSelection.value = min(max(slashSelection.value + delta, 0), count - 1)
        return .handled
    }

    private func acceptSlash() -> KeyPress.Result {
        let matches = slashMatches
        guard !matches.isEmpty else { return .ignored }
        accept(matches[min(slashSelection.value, matches.count - 1)])
        return .handled
    }

    private func accept(_ command: SlashCommand) {
        chat.draft = command.insertion
        focused.wrappedValue = true
    }
}
