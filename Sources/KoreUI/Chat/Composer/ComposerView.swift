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
    /// The window's tabs: what's open over them closes on Esc before anything in the chat.
    let workspace: Workspace
    var focused: FocusState<Bool>.Binding
    let openImage: (Attachment) -> Void
    @StateObject private var slashSelection = Local(0)
    /// The @ menu's search and its lit row.
    @StateObject private var mentions = AtSearch()
    @StateObject private var mentionSelection = Local(0)
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
    /// The bar under the text (global): a press on it closes what's open over the composer.
    @StateObject private var barFrame = Held<CGRect>(.zero)
    @StateObject private var slashFrame = Held<CGRect>(.zero)
    @StateObject private var clickMonitor = Held<Any?>(nil)
    /// The caret Kore last placed, with the draft it had just set: a range is only good in the
    /// text it was made for. The text view takes it once it shows that text.
    @StateObject private var caret = Local<ComposerText.Placed?>(nil)
    /// The text view and its undo, read outside updates; never shown.
    @StateObject private var editor = ComposerEditor()
    /// What the / button last put in: the "/" (after a space of its own when the caret ended a
    /// word) in place of the text selected. While the text before it is the same, the button
    /// takes the "/word" out with that space and puts the selected text back.
    @StateObject private var slashInsert = Held<SlashInsert?>(nil)
    /// ⌘A has the whole draft, chips and all (`ComposerTextView.wholeDraft`): the chips show
    /// selected.
    @StateObject private var wholeDraft = Local(false)
    /// A whole draft going in (⌘V): its own edit of the text takes no chips with it.
    @StateObject private var pastingDraft = Held(false)
    /// The sent message ↑ brought back into the empty box, while the box still holds it as it
    /// came (`recall`).
    @StateObject private var recalled = Held<Recalled?>(nil)

    struct Recalled {
        let chat: UUID
        /// How far back: 0 the newest message.
        let back: Int
        let draft: String
        let command: SlashCommand?
    }

    struct SlashInsert {
        let chat: UUID
        /// The draft before the "/", with the space the button put.
        let before: String
        let spaced: Bool
        let replaced: String
    }

    /// Puts the caret at `offset` characters into the draft just set; nil, at its end (found
    /// without counting a long draft's characters, as a tab switch does it).
    private func place(at offset: Int? = nil) {
        let draft = chat.draft
        let location = offset.map { offset in
            let index = draft.index(draft.startIndex, offsetBy: min(max(offset, 0), draft.count))
            return NSRange(index..<index, in: draft).location
        } ?? draft.utf16.count
        caret.value = ComposerText.Placed(
            chat: chat.id, range: NSRange(location: location, length: 0), text: draft, serial: (caret.value?.serial ?? 0) + 1)
    }

    /// Empty, except while a turn runs (look.md §10): a message sent then waits for it, or joins
    /// it where the CLI can steer (Codex).
    private var placeholder: String {
        if chat.accountRestartPending { return "Switching accounts…" }
        // With a command and nothing typed: what the command takes ("objective").
        if let hint = chat.command?.hint, !hint.isEmpty, chat.draft.isEmpty { return hint }
        guard chat.status.isRunning else {
            // Known before sending: what's sent waits for the network.
            return NetworkWatch.shared.isOnline ? "" : "Offline · what you send goes when you're back"
        }
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
                        select: { slashSelection.value = $0 }, accept: accept)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { menuFrame.value = $0 }
                        .onDisappear { menuFrame.value = nil }
                        // Its bottom a gap above the box's top, its height its own.
                        .padding(.bottom, Space.lg)
                        .frame(height: 0, alignment: .bottom)  // lint:allow a zero-height anchor, not a size
                } else if mentionShown {
                    let items = mentions.results
                    AtMenu(
                        items: items, selected: min(mentionSelection.value, items.count - 1),
                        select: { mentionSelection.value = $0 }, accept: acceptMention)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { menuFrame.value = $0 }
                        .onDisappear { menuFrame.value = nil }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, Space.lg)
                        .frame(height: 0, alignment: .bottom)  // lint:allow a zero-height anchor, not a size
                } else if chat.usage.isOpen {
                    // In the menu's place, its height at most the room above the box.
                    let box = boxFrame.value
                    UsagePopup(
                        chat: chat, state: chat.usage, wording: chat.provider.usage,
                        room: max(box.minY - Size.titleRow - Space.lg - Space.xxxl, Size.usageMinRoom)
                    )
                    .padding(.bottom, Space.lg)
                    .frame(height: 0, alignment: .bottom)  // lint:allow a zero-height anchor, not a size
                } else if chat.account.isOpen {
                    AccountPopup(
                        chat: chat, state: chat.account,
                        room: max(boxFrame.value.minY - Size.titleRow - Space.lg - Space.xxxl, Size.usageMinRoom))
                        .padding(.bottom, Space.lg)
                        .frame(height: 0, alignment: .bottom)  // lint:allow a zero-height anchor, not a size
                } else if let kind = chat.picker.open {
                    Group {
                        switch kind {
                        case .model: ModelPicker(chat: chat, state: chat.picker)
                        case .mode: ModePicker(chat: chat, state: chat.picker)
                        }
                    }
                    .padding(.bottom, Space.lg)
                    .frame(height: 0, alignment: .bottom)  // lint:allow a zero-height anchor, not a size
                } else if chat.importer.isOpen {
                    ImportPopup(chat: chat, state: chat.importer) {
                        ImportFilePanel.choose(for: chat.provider, in: window.value) { chat.importer.add(file: $0) }
                    }
                    .padding(.bottom, Space.lg)
                    .frame(height: 0, alignment: .bottom)  // lint:allow a zero-height anchor, not a size
                }
            }
        .background(WindowReader { window.value = $0 })
        .animation(Motion.fadeSlow, value: chat.controls.activeMode.id)
        .onAppear {
            pasteChat.value = chat
            pasteMonitor.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                pasteAttachments(event)
            }
            clickMonitor.value = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { closeMenu(onClick: $0) }
        }
        .onDisappear {
            for monitor in [pasteMonitor.value, clickMonitor.value].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
            pasteMonitor.value = nil
            clickMonitor.value = nil
            chat.usage.close()
            chat.account.close()
            chat.importer.close()
            chat.picker.close()
        }
        // A field or form in the Account popup had the keys: when it goes, the composer has them
        // again, as it has throughout everything else in the popup.
        .onChange(of: chat.account.isEditing) { _, editing in
            if !editing { focused.wrappedValue = true }
        }
        .onChange(of: chat.id) {
            // The popups are the chat the box showed; they close with the switch.
            pasteChat.value?.usage.close()
            pasteChat.value?.account.close()
            pasteChat.value?.importer.close()
            pasteChat.value?.picker.close()
            pasteChat.value = chat
            // The caret goes to the end of this chat's draft, ready to go on typing.
            place()
            slashSelection.value = 0
            mentionSelection.value = 0
            recalled.value = nil
            mentions.close()
            if chat.slashClosed { chat.slashClosed = false }
            forgetUndo()
        }
    }

    /// The text stays focused through a switch, and its undo was the last chat's typing: undone
    /// here, it would edit this chat's draft. The text view keeps its own undo manager (not the
    /// window's, which the explorer's file moves use), so all of it goes.
    private func forgetUndo() {
        editor.undo?.removeAllActions()
        editor.view?.breakUndoCoalescing()
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
                            AttachmentChip(
                                attachment: attachment, selected: wholeDraft.value, focused: focused.wrappedValue,
                                open: { openImage(attachment) }
                            ) {
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
            ComposerBar(chat: chat, attach: attach, slash: toggleSlash) { slashFrame.value = $0 }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { barFrame.value = $0 }
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
                CommandChip(
                    command: command, selection: wholeDraft.value ? Theme.Selection.chip(focused: focused.wrappedValue) : nil,
                    open: openSlash)
            }
            textField
        }
        .padding(Inset.field)
        // A click on the padding around the text focuses it with the caret at the nearest
        // point of the text (below the last line, its end) rather than landing on nothing; a
        // click in the text puts the caret there.
        .contentShape(Rectangle())
        .onTapGesture {
            focused.wrappedValue = true
            if let event = NSApp.currentEvent, event.type == .leftMouseUp || event.type == .leftMouseDown {
                editor.placeCaret(at: event.locationInWindow)
            }
        }
    }

    private var textField: some View {
        let font = TextStyle.bodyFont
        let baseline = ComposerText.baseline(font)
        return ComposerText(
            chat: chat.id, text: chat.draft, font: font, placed: caret.value, editor: editor,
            changed: { chat.draft = $0 }, command: perform,
            draft: ComposerText.WholeDraft(
                hasMore: { !chat.attachments.isEmpty || chat.command != nil },
                selected: selectWhole,
                clipboard: clipboard,
                replaced: { if !pastingDraft.value { setMore(attachments: [], command: nil) } })
        )
        .focused(focused)
        .alignmentGuide(.firstTextBaseline) { _ in baseline }
        .overlay(alignment: .topLeading) {
            if chat.draft.isEmpty, !placeholder.isEmpty {
                Text(placeholder)
                    .font(TextStyle.body)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .allowsHitTesting(false)
            }
        }
        .storyID(StoryID.Composer.field)
        .onChange(of: slashToken) { old, new in
            slashSelection.value = 0
            // Typed: the first row is lit, whatever the menu opens under.
            PointerGate.keyed()
            // Esc closes the menu for this "/word"; the next one opens it again.
            if new?.range.lowerBound != old?.range.lowerBound, chat.slashClosed { chat.slashClosed = false }
        }
        // One popup at a time: the menu showing closes the rest.
        .onChange(of: slashMatches.isEmpty) { _, empty in if !empty { chat.closePopups(keeping: .slash) } }
        .onChange(of: mentionToken) { old, new in mentionChanged(old, new) }
        .onChange(of: mentionShown) { _, shown in if shown { chat.closePopups(keeping: .slash) } }
    }

    /// The keys the composer gives a meaning, as the text view's commands: true when taken.
    private func perform(_ view: ComposerTextView, _ command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
            #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // Shift+Return (and Option+Return) start a new line; Return sends.
            if let key = view.key, !key.modifierFlags.isDisjoint(with: [.shift, .option]) {
                view.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            if acceptSlash() == .ignored, acceptMentionKey() == .ignored { chat.send() }
            return true
        // Shift+Tab switches mode, as in both CLIs; plain Tab accepts a slash command, else
        // indents by four spaces, as in an editor.
        case #selector(NSResponder.insertBacktab(_:)):
            chat.cycleMode()
            return true
        case #selector(NSResponder.insertTab(_:)):
            if acceptSlash() == .ignored, acceptMentionKey() == .ignored { view.insertText("    ", replacementRange: view.selectedRange()) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Taken either way: the text view's own Esc would open a completion list.
            escape(view)
            return true
        case #selector(NSResponder.moveUp(_:)):
            return moveSlash(-1) == .handled || moveMention(-1) == .handled || recall(view, older: true)
        case #selector(NSResponder.moveDown(_:)):
            return moveSlash(1) == .handled || moveMention(1) == .handled || recall(view, older: false)
        case #selector(NSResponder.deleteBackward(_:)) where !view.wholeDraft:
            return removeCommand(view)
        default:
            // Backspace (any delete) with ⌘A's whole draft and no text: the chips go. With
            // text, the text view deletes it, and the chips go with it (`replaced`).
            if view.wholeDraft, view.string.isEmpty, NSStringFromSelector(command).hasPrefix("delete") {
                setMore(attachments: [], command: nil)
                view.endWholeDraft()
                return true
            }
            return false
        }
    }

    /// Esc, a step at a time (`EscStep`). The popups' own monitors take it before the field
    /// does; they're closed here too, so no Esc gets past one to the turn.
    private func escape(_ view: NSTextView) {
        let selection = chat.transcript.selection
        switch EscStep.next(
            overlay: workspace.hasOverlay, slashMenu: !slashMatches.isEmpty || mentionShown, popup: chat.hasPopup, selection: selection.hasSelection,
            running: chat.isBusy, sheet: view.window?.attachedSheet != nil || NSApp.modalWindow != nil)
        {
        case .closeOverlay: workspace.closeOverlay()
        case .closeSlashMenu: chat.slashClosed = true
        case .closePopup: chat.closePopups()
        case .clearSelection: selection.clear()
        case .stop: chat.stop()
        case .nothing: break
        }
    }

    // MARK: Sent messages (↑ ↓)

    /// The message ↑ brought back, while the box holds it untouched; nil once it's edited (a
    /// draft of its own then).
    private var recalling: Recalled? {
        guard let kept = recalled.value, kept.chat == chat.id, kept.draft == chat.draft, kept.command == chat.command,
            chat.attachments.isEmpty
        else { return nil }
        return kept
    }

    /// ↑ in an empty box brings back this chat's last sent message, as a shell does its last
    /// command; ↑ again an older one, ↓ a newer one, and past the newest the box is empty again.
    /// A message brought back steps on from its first line (↑) or its last (↓), so one of
    /// several lines can still be moved about in; ↑ leaves the caret at its start and ↓ at its
    /// end, so the same key steps on at once. Its text only: files sent with it stay out.
    private func recall(_ view: ComposerTextView, older: Bool) -> Bool {
        guard !composing, view.shown == chat.draft, view.selectedRange().length == 0 else { return false }
        let kept = recalling
        if kept == nil {
            recalled.value = nil
            guard older, chat.draft.isEmpty, chat.command == nil, chat.attachments.isEmpty else { return false }
        } else if !(older ? view.caretOnFirstLine : view.caretOnLastLine) {
            return false
        }
        let messages = chat.transcript.sentMessages
        let back = (kept?.back ?? -1) + (older ? 1 : -1)
        // The oldest stays; an empty chat has nothing to bring back.
        guard back < messages.count else { return kept != nil }
        if back < 0 {
            recalled.value = nil
            chat.command = nil
            chat.draft = ""
        } else {
            let (command, draft) = Chat.split(messages[messages.count - 1 - back], commands: chat.controls.commands)
            // Set before the draft: the menus read it as the box shows the message.
            recalled.value = Recalled(chat: chat.id, back: back, draft: draft, command: command)
            chat.command = command
            chat.draft = draft
        }
        place(at: older ? 0 : nil)
        forgetUndo()
        return true
    }

    // MARK: Paste and +

    /// ⌘V in this chat's composer with files or an image on the clipboard attaches them;
    /// anything else (text) pastes normally.
    private func pasteAttachments(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers == "v",
            let window = window.value, event.window === window,
            let view = editor.view, window.firstResponder === view, let chat = pasteChat.value
        else { return event }
        let board = DraftClipboard.pasteboard
        if let draft = DraftClipboard.read(from: board) {
            paste(draft, into: chat)
            return nil
        }
        guard let urls = Attachments.fromPasteboard(board) else { return event }
        chat.attach(urls)
        return nil
    }

    // MARK: The whole draft (⌘A)

    private func selectWhole(_ whole: Bool) {
        wholeDraft.value = whole
        guard whole, let chat = pasteChat.value else { return }
        UILog.event("composer-select-all", Self.counts(chat.attachments, command: chat.command))
    }

    /// Counts for the log, never the text or the names.
    private static func counts(_ attachments: [Attachment], command: SlashCommand?) -> KeyValuePairs<String, String?> {
        [
            "images": String(attachments.filter { $0.kind == .image }.count),
            "files": String(attachments.filter { $0.kind != .image }.count),
            "command": command == nil ? "no" : "yes",
        ]
    }

    /// ⌘C ⌘X with ⌘A's whole draft: all of it to the clipboard (`DraftClipboard`), and for ⌘X
    /// out of the box, as Backspace takes it. ⌘V with a whole draft on the clipboard: it goes
    /// in. Anything else is the text view's own.
    private func clipboard(_ view: ComposerTextView, _ action: ComposerTextView.Clipboard) -> Bool {
        guard let chat = pasteChat.value else { return false }
        switch action {
        case .copy, .cut:
            guard view.wholeDraft, view.shown == chat.draft else { return false }
            DraftClipboard(provider: chat.provider.id, text: chat.draft, command: chat.command, attachments: chat.attachments)
                .write(to: DraftClipboard.pasteboard)
            UILog.event(action == .cut ? "composer-cut-all" : "composer-copy-all", Self.counts(chat.attachments, command: chat.command))
            if action == .cut {
                if view.string.isEmpty {
                    setMore(attachments: [], command: nil)
                    view.endWholeDraft()
                } else {
                    view.delete(nil)
                }
            }
            return true
        case .paste:
            guard let draft = DraftClipboard.read(from: DraftClipboard.pasteboard) else { return false }
            paste(draft, into: chat)
            return true
        }
    }

    /// A copied draft into this one: its text at the caret (in place of what's selected), its
    /// files after the chips there are, in their order, and its command in the chip when the
    /// chip is free and the command is this CLI's (else as "/name" before the text). Over ⌘A's
    /// whole draft, it replaces all of it. One undo takes it out again.
    private func paste(_ draft: DraftClipboard, into chat: Chat) {
        let replacingAll = editor.view?.wholeDraft == true
        let before = replacingAll ? [] : chat.attachments
        var command = replacingAll ? nil : chat.command
        var text = draft.text
        if let copied = draft.command, copied.kind == .command {
            let known =
                draft.provider == chat.provider.id
                ? copied.slashCommand
                : chat.controls.commands.first { $0.kind == .command && $0.name == copied.name }
            if command == nil, let known {
                command = known
            } else {
                text = text.isEmpty ? "/\(copied.name)" : "/\(copied.name) \(text)"
            }
        }
        let pasted = draft.urls().map(Attachment.init(url:))
        if let view = editor.view, view.shown == chat.draft, !text.isEmpty || replacingAll {
            let range = view.selectedRange()
            pastingDraft.value = true
            view.breakUndoCoalescing()
            if view.shouldChangeText(in: range, replacementString: text) {
                view.replaceCharacters(in: range, with: text)
                view.didChangeText()
                view.setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
                view.scrollRangeToVisible(view.selectedRange())
            }
            pastingDraft.value = false
        } else if !text.isEmpty || replacingAll {
            chat.draft = replacingAll ? text : chat.draft + text
            place()
        }
        editor.view?.endWholeDraft()
        setMore(attachments: before + pasted, command: command)
        editor.view?.breakUndoCoalescing()
        UILog.event("composer-paste-all", Self.counts(pasted, command: draft.command?.slashCommand))
    }

    /// Sets the chips (and the command), undoably in the text's own undo: a clear or a paste of
    /// the whole draft comes back with ⌘Z, the chips with the text.
    private func setMore(attachments: [Attachment], command: SlashCommand?) {
        guard let chat = pasteChat.value else { return }
        Self.swap(chat, attachments: attachments, command: command, undo: editor.undo)
    }

    private static func swap(_ chat: Chat, attachments: [Attachment], command: SlashCommand?, undo: UndoManager?) {
        let attachmentsBefore = chat.attachments
        let commandBefore = chat.command
        guard attachmentsBefore.map(\.id) != attachments.map(\.id) || commandBefore != command else { return }
        undo?.registerUndo(withTarget: chat) { [weak undo] chat in
            MainActor.assumeIsolated { swap(chat, attachments: attachmentsBefore, command: commandBefore, undo: undo) }
        }
        chat.setAttachments(attachments)
        chat.command = command
    }

    /// Backspace with the caret before the first character takes the command chip off; the
    /// text stays.
    private func removeCommand(_ view: NSTextView) -> Bool {
        guard chat.command != nil, !view.hasMarkedText(), view.selectedRange() == NSRange(location: 0, length: 0) else { return false }
        chat.command = nil
        return true
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

    /// What's selected in this chat's draft (empty: the caret), read from the text view while
    /// it shows this draft, else a caret Kore placed in this very text; nil when not known. The
    /// view's selection is never carried into another text: it can belong to the text a
    /// keystroke ahead, and an index of one string used in another traps.
    private var selectedRange: Range<String.Index>? {
        let draft = chat.draft
        if let view = editor.view, view.shown == draft { return Range(view.selectedRange(), in: draft) }
        guard let kept = caret.value, kept.chat == chat.id, kept.text == draft else { return nil }
        return Range(kept.range, in: draft)
    }

    /// Where the caret is in this chat's draft: the end when it isn't known, nil with a range
    /// selected.
    private var caretIndex: String.Index? {
        guard let range = selectedRange else { return chat.draft.endIndex }
        return range.isEmpty ? range.lowerBound : nil
    }

    /// The "/word" at the caret (or Codex's "$word"), anywhere in the draft.
    private var slashToken: SlashToken? {
        guard recalling == nil, let caret = caretIndex else { return nil }
        return SlashToken(in: chat.draft, caret: caret, skills: chat.provider == .codex)
    }

    private var slashMatches: [SlashCommand] {
        guard !chat.slashClosed, let token = slashToken else { return [] }
        return SlashCommand.matches(chat.controls.commands, sigil: token.sigil, query: token.query)
    }

    /// An input method is composing (marked text): its keys are its own.
    private var composing: Bool { editor.view?.hasMarkedText() ?? false }

    private func moveSlash(_ delta: Int) -> KeyPress.Result {
        let count = slashMatches.count
        guard count > 0, !composing else { return .ignored }
        slashSelection.value = min(max(slashSelection.value + delta, 0), count - 1)
        PointerGate.keyed()
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
        chat.slashClosed = false
        focused.wrappedValue = true
        if slashToken != nil { return }
        var draft = chat.draft
        let range = selectedRange ?? draft.endIndex..<draft.endIndex
        let spaced = range.lowerBound > draft.startIndex && !draft[draft.index(before: range.lowerBound)].isWhitespace
        let offset = draft.distance(from: draft.startIndex, to: range.lowerBound) + (spaced ? 2 : 1)
        slashInsert.value = SlashInsert(
            chat: chat.id, before: String(draft[..<range.lowerBound]) + (spaced ? " " : ""), spaced: spaced,
            replaced: String(draft[range]))
        draft.replaceSubrange(range, with: spaced ? " /" : "/")
        chat.draft = draft
        place(at: offset)
    }

    /// The / button: with the menu showing for a "/word", the menu closes and the word goes, the
    /// caret where it was. One the button put in goes as it came (`SlashInsert`); one typed goes
    /// with a space after it (`SlashToken.removal`). The text view makes the edit, so ⌘Z puts
    /// the word back. A Codex "$skill" is the message's own text: the menu only closes over it.
    /// Without the menu, the button opens it (`openSlash`).
    private func toggleSlash() {
        guard !slashMatches.isEmpty, let token = slashToken else { return openSlash() }
        focused.wrappedValue = true
        guard token.sigil == "/", !composing else {
            chat.slashClosed = true
            return
        }
        let draft = chat.draft
        let inserted = slashInsert.value.flatMap { $0.chat == chat.id && draft[..<token.range.lowerBound] == $0.before ? $0 : nil }
        slashInsert.value = nil
        var removed = token.removal(in: draft)
        var replacement = ""
        if let inserted {
            removed = (inserted.spaced ? draft.index(before: token.range.lowerBound) : token.range.lowerBound)..<token.range.upperBound
            replacement = inserted.replaced
        }
        let range = NSRange(removed, in: draft)
        if let view = editor.view, view.shown == draft, view.shouldChangeText(in: range, replacementString: replacement) {
            view.breakUndoCoalescing()
            view.replaceCharacters(in: range, with: replacement)
            view.didChangeText()
            view.breakUndoCoalescing()
            // The text the "/" took the place of comes back selected, as it was.
            view.setSelectedRange(NSRange(location: range.location, length: (replacement as NSString).length))
        } else {
            var text = draft
            text.replaceSubrange(removed, with: replacement)
            chat.draft = text
            place(at: draft.distance(from: draft.startIndex, to: removed.lowerBound) + replacement.count)
        }
    }

    /// A pick replaces the "/word" it was filtered by: a command goes to the chip (one per
    /// message, so it replaces any there), a Codex skill in the text as "$name ". Usage and
    /// Account only take the word out, and open their popup where the menu was. The caret stays where the
    /// word was, and the field's undo starts over, as its text was set.
    private func accept(_ command: SlashCommand) {
        let insertion = command.kind == .skill ? command.insertion : ""
        let (draft, caret) = slashToken.map { $0.replacing(in: chat.draft, with: insertion) } ?? (chat.draft, chat.draft.count)
        if command.kind == .command { chat.command = command }
        chat.draft = draft
        place(at: caret)
        chat.slashClosed = false
        focused.wrappedValue = true
        forgetUndo()
        if command.kind == .kore {
            if command.name == SlashCommand.account.name { chat.openAccount() } else { chat.openUsage() }
        }
    }

    // MARK: @ mentions

    /// The "@word" at the caret: the @ menu's search.
    private var mentionToken: SlashToken? {
        guard recalling == nil, let caret = caretIndex,
            let token = SlashToken(in: chat.draft, caret: caret, skills: false, mentions: true),
            token.sigil == "@"
        else { return nil }
        return token
    }

    private var mentionShown: Bool {
        !chat.slashClosed && !mentions.results.isEmpty && slashMatches.isEmpty && mentionToken != nil
    }

    /// What the search runs over, read here: the folder's files join it in `AtSearch`.
    private var mentionCandidates: AtCandidates {
        let controls = chat.controls
        let tabs = workspace.tabs.filter { $0.id != workspace.activeTab.id && !$0.isEmpty }
        return AtCandidates(
            recent: workspace.recentFiles.map(workspace.relativePath), models: controls.models, currentModel: controls.modelId,
            skills: controls.commands.filter { $0.kind == .skill },
            tabs: tabs.map { AtCandidates.Tab(id: $0.id.uuidString, title: $0.title) })
    }

    /// A new "@" lists the folder again; each keystroke in it searches (`AtSearch` waits a
    /// moment and ranks off the main thread). Esc closes the menu for this "@word" only.
    private func mentionChanged(_ old: SlashToken?, _ new: SlashToken?) {
        mentionSelection.value = 0
        guard let new else { return mentions.close() }
        PointerGate.keyed()
        if new.range.lowerBound != old?.range.lowerBound {
            if chat.slashClosed { chat.slashClosed = false }
            if old == nil { mentions.open(chat.folder) }
        }
        mentions.search(new.query, mentionCandidates, wait: !new.query.isEmpty)
    }

    private func moveMention(_ delta: Int) -> KeyPress.Result {
        let count = mentions.results.count
        guard mentionShown, count > 0, !composing else { return .ignored }
        mentionSelection.value = min(max(mentionSelection.value + delta, 0), count - 1)
        PointerGate.keyed()
        return .handled
    }

    private func acceptMentionKey() -> KeyPress.Result {
        let items = mentions.results
        guard mentionShown, !items.isEmpty, !composing else { return .ignored }
        acceptMention(items[min(mentionSelection.value, items.count - 1)])
        return .handled
    }

    /// A pick takes the "@word" out: a file or folder goes in as a chip, as + attaches it (a
    /// Codex chip reaches the model as a note with its path, `Attachments.codexInput`); a model
    /// becomes the chat's; a skill goes in as "$name "; a tab comes to the front.
    private func acceptMention(_ item: AtItem) {
        let shown = mentions.results
        let insertion = item.kind == .skill ? "$\(item.key) " : ""
        let (draft, caret) = mentionToken.map { $0.replacing(in: chat.draft, with: insertion) } ?? (chat.draft, chat.draft.count)
        chat.draft = draft
        place(at: caret)
        mentions.close()
        chat.slashClosed = false
        focused.wrappedValue = true
        forgetUndo()
        switch item.kind {
        case .file, .folder:
            let url = chat.folder.appendingPathComponent(item.key, isDirectory: item.kind == .folder)
            if !chat.attachments.contains(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) { chat.attach([url]) }
        case .model:
            if item.key != chat.controls.modelId, let option = chat.controls.models.first(where: { $0.id == item.key }) {
                chat.setModel(option)
            }
        case .skill:
            break
        case .tab:
            if let tab = workspace.tabs.first(where: { $0.id.uuidString == item.key }) { workspace.select(tab) }
        }
        UILog.event(
            "composer-mention",
            [
                "cli": chat.provider.id, "kind": item.kind.name, "rows": String(shown.count),
                "kinds": AtItem.Kind.allCases.filter { kind in shown.contains { $0.kind == kind } }.map(\.name).joined(separator: ","),
            ])
    }

    /// A click outside the menu and the box closes the menu, and a press on the bar under the
    /// text (a chip, +, the context wheel) closes whatever is open before its own menu or panel
    /// opens, which the system's menus then hold the events for. The click goes on as it was.
    private func closeMenu(onClick event: NSEvent) -> NSEvent? {
        guard let window = window.value, event.window === window, let content = window.contentView else { return event }
        // Window coordinates (bottom-left) to SwiftUI's global ones (top-left).
        let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        guard let chat = pasteChat.value else { return event }
        if barFrame.value.contains(point) {
            // A picker's own chip leaves it to the chip, which closes it.
            let chip = chat.picker.chips.first { $0.value.contains(point) }?.key
            chat.closePopups(keeping: slashFrame.value.contains(point) ? .slash : chip?.popup)
        } else if let menu = menuFrame.value, !menu.contains(point), !boxFrame.value.contains(point) {
            chat.slashClosed = true
        }
        return event
    }
}
