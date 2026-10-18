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
                        select: { slashSelection.value = $0 }, accept: accept)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { menuFrame.value = $0 }
                        .onDisappear { menuFrame.value = nil }
                        // Its bottom a gap above the box's top, its height its own.
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
                    AccountPopup(chat: chat, state: chat.account)
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
            ComposerBar(chat: chat, attach: attach, slash: openSlash) { slashFrame.value = $0 }
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
                CommandChip(command: command, open: openSlash)
            }
            textField
        }
        .padding(Inset.field)
        // A click on the padding around the text focuses it at once rather than landing on
        // nothing; a click in the text puts the caret there.
        .contentShape(Rectangle())
        .onTapGesture { focused.wrappedValue = true }
    }

    private var textField: some View {
        let font = TextStyle.bodyFont
        let baseline = ComposerText.baseline(font)
        return ComposerText(
            chat: chat.id, text: chat.draft, font: font, placed: caret.value, editor: editor,
            changed: { chat.draft = $0 }, command: perform
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
            if acceptSlash() == .ignored { chat.send() }
            return true
        // Shift+Tab switches mode, as in both CLIs; plain Tab accepts a slash command, else
        // moves on as a field's Tab does.
        case #selector(NSResponder.insertBacktab(_:)):
            chat.cycleMode()
            return true
        case #selector(NSResponder.insertTab(_:)):
            if acceptSlash() == .ignored { view.window?.selectNextKeyView(nil) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Taken either way: the text view's own Esc would open a completion list.
            escape(view)
            return true
        case #selector(NSResponder.moveUp(_:)):
            return moveSlash(-1) == .handled
        case #selector(NSResponder.moveDown(_:)):
            return moveSlash(1) == .handled
        case #selector(NSResponder.deleteBackward(_:)):
            return removeCommand(view)
        default:
            return false
        }
    }

    /// Esc, a step at a time (`EscStep`). The popups' own monitors take it before the field
    /// does; they're closed here too, so no Esc gets past one to the turn.
    private func escape(_ view: NSTextView) {
        let selection = chat.transcript.selection
        switch EscStep.next(
            overlay: workspace.hasOverlay, slashMenu: !slashMatches.isEmpty, popup: chat.hasPopup, selection: selection.hasSelection,
            running: chat.status.isRunning, sheet: view.window?.attachedSheet != nil || NSApp.modalWindow != nil)
        {
        case .closeOverlay: workspace.closeOverlay()
        case .closeSlashMenu: chat.slashClosed = true
        case .closePopup: chat.closePopups()
        case .clearSelection: selection.clear()
        case .stop: chat.stop()
        case .nothing: break
        }
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
        guard let caret = caretIndex else { return nil }
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
        draft.replaceSubrange(range, with: spaced ? " /" : "/")
        chat.draft = draft
        place(at: offset)
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
