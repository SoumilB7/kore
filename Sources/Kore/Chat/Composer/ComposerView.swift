import AppKit
import SwiftUI

/// The input box: attachments, text, and the bar of controls under it, with the slash menu
/// above it while a command is being typed. Files can be pasted (⌘V), picked (+), or dropped
/// onto the box.
struct ComposerView: View {
    let chat: ChatModel
    var focused: FocusState<Bool>.Binding
    let openImage: (Attachment) -> Void
    @StateObject private var slashSelection = Local(0)
    @StateObject private var slashDismissed = Local(false)
    @StateObject private var window = Local<NSWindow?>(nil)
    @StateObject private var pasteMonitor = Local<Any?>(nil)
    @StateObject private var dropTargeted = Local(false)

    var body: some View {
        VStack(spacing: Space.lg) {
            if !slashMatches.isEmpty {
                SlashMenu(matches: slashMatches, selected: min(slashSelection.value, slashMatches.count - 1), accept: accept)
            }
            box
        }
        .background(WindowReader { window.value = $0 })
        .animation(Motion.fadeSlow, value: chat.activeMode.id)
        .onAppear {
            pasteMonitor.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { pasteAttachments($0) }
        }
        .onDisappear {
            if let monitor = pasteMonitor.value { NSEvent.removeMonitor(monitor) }
            pasteMonitor.value = nil
        }
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
        .modeOutline(chat.activeMode.rung, focused: focused.wrappedValue, highlighted: dropTargeted.value)
        // Only the box takes drops; the rest of the chat ignores them.
        .onDrop(of: [.fileURL, .image], isTargeted: Binding(get: { dropTargeted.value }, set: { dropTargeted.value = $0 })) { providers in
            Attachments.load(providers) { chat.attach($0) }
            focused.wrappedValue = true
            return true
        }
    }

    private var field: some View {
        TextField("", text: Binding(get: { chat.draft }, set: { chat.draft = $0 }), axis: .vertical)
            .textFieldStyle(.plain)
            .font(TextStyle.body)
            .foregroundStyle(Theme.text)
            .lineLimit(1...10)
            .focused(focused)
            .onSubmit { chat.send() }
            .onKeyPress(.upArrow) { moveSlash(-1) }
            .onKeyPress(.downArrow) { moveSlash(1) }
            .onKeyPress(.return) { acceptSlash() }
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

    private var slashMatches: [ChatModel.SlashCommand] {
        guard !slashDismissed.value, let query = slashQuery else { return [] }
        // Foundation's `contains("")` is false, so a bare "/" must list everything explicitly.
        if query.isEmpty { return chat.commands }
        let hits = chat.commands.filter { $0.name.lowercased().contains(query) }
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

    private func accept(_ command: ChatModel.SlashCommand) {
        chat.draft = command.insertion
        focused.wrappedValue = true
    }
}
