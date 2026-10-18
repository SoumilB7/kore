import AppKit
import SwiftUI

struct ChatView: View {
    @Bindable var chat: ChatModel
    @Environment(\.chatColumn) private var column
    @FocusState private var composerFocused: Bool
    @StateObject private var plusHovered = Local(false)
    @StateObject private var slashSelection = Local(0)
    @StateObject private var slashDismissed = Local(false)
    @StateObject private var window = Local<NSWindow?>(nil)
    @StateObject private var pasteMonitor = Local<Any?>(nil)
    @StateObject private var dropTargeted = Local(false)
    @StateObject private var viewer = Local<ImageEditor?>(nil)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(chat.entries) { EntryView(entry: $0, openImage: { view($0, pending: false) }) }
                }
                .padding(.horizontal, column.padding)
                .padding(.vertical, 20)
                .frame(maxWidth: column.maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)

            VStack(spacing: 10) {
                ForEach(chat.approvals) { approval in
                    if let plan = approval.plan {
                        PlanApprovalCard(plan: plan) { chat.answer(approval, $0) }
                    } else if approval.questions.isEmpty {
                        PermissionCard(approval: approval) { chat.answer(approval, $0) }
                    } else {
                        QuestionCard(approval: approval) { chat.answer(approval, .answers($0)) }
                    }
                }
                if chat.offerImplementPlan && !chat.isRunning {
                    ImplementPlanCard(implement: chat.implementPlan, stay: chat.stayInPlanMode)
                }
                if !slashMatches.isEmpty { slashMenu }
                composer
            }
            .padding(.horizontal, ChatColumn.window.padding)
            .padding(.bottom, 16)
            .frame(maxWidth: ChatColumn.window.maxWidth)
        }
        .overlay {
            if let editor = viewer.value {
                ImageViewer(
                    editor: editor, actionTitle: editor.pendingID == nil ? "Add to message" : "Done",
                    finish: { finishViewing(editor) }, close: closeViewer
                )
            }
        }
        .animation(.easeOut(duration: 0.25), value: chat.activeMode.id)
        .animation(.easeOut(duration: 0.15), value: viewer.value?.id)
        .background(WindowReader { window.value = $0 })
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted.value) { providers in
            Attachments.load(providers) { chat.attach($0) }
            return true
        }
        .onAppear {
            composerFocused = true
            pasteMonitor.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { pasteAttachments($0) }
        }
        .onDisappear {
            if let monitor = pasteMonitor.value { NSEvent.removeMonitor(monitor) }
            pasteMonitor.value = nil
        }
        .task { await chat.start() }
    }

    /// ⌘V in this chat's composer with files or an image on the clipboard attaches them;
    /// anything else (text) pastes normally.
    private func pasteAttachments(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers == "v",
            let window = window.value, event.window === window, composerFocused,
            let urls = Attachments.fromPasteboard(.general)
        else { return event }
        chat.attach(urls)
        return nil
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if !chat.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chat.attachments) { attachment in
                            AttachmentChip(attachment: attachment, open: { view(attachment, pending: true) }) {
                                chat.removeAttachment(attachment.id)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                }
            }
            TextField("", text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .foregroundStyle(Theme.text)
                .lineLimit(1...10)
                .focused($composerFocused)
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
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Rectangle().fill(Theme.border).frame(height: 1)

            HStack(spacing: 14) {
                Button(action: attach) {
                    Image(systemName: "plus")
                        .font(.kore(14))
                        .foregroundStyle(plusHovered.value ? Theme.text : Theme.secondary)
                }
                .buttonStyle(.plain)
                .onHover { plusHovered.value = $0 }
                .help("Attach files and images")

                Button {
                    if chat.draft.isEmpty { chat.draft = "/" }
                    composerFocused = true
                } label: {
                    Text("/")
                        .font(.kore(11, .semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 16, height: 16)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.secondary, lineWidth: 1.2))
                }
                .buttonStyle(.plain)
                .help("Slash commands")

                if !chat.models.isEmpty { modelMenu }

                Spacer()

                if chat.provider == .codex && chat.planMode {
                    PlanChip { chat.setPlanMode(false) }
                }
                modeMenu

                Button {
                    chat.isRunning ? chat.stop() : chat.send()
                } label: {
                    Image(systemName: chat.isRunning ? "stop.fill" : "arrow.up")
                        .font(.kore(12, .bold))
                        .foregroundStyle(Theme.background)
                        .frame(width: 28, height: 28)
                        .background(Theme.text, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(!chat.isRunning && !chat.canSend)
                .opacity(!chat.isRunning && !chat.canSend ? 0.3 : 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(composerBorder, lineWidth: 1))
    }

    private var composerBorder: Color {
        if let tint = chat.tint { return tint.opacity(composerFocused ? 0.7 : 0.45) }
        return composerFocused ? Theme.text.opacity(0.22) : Theme.border
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
        composerFocused = true
    }

    private var slashMenu: some View {
        let matches = slashMatches
        let selected = min(slashSelection.value, matches.count - 1)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                        HStack(spacing: 8) {
                            Text(command.kind == .skill ? "$\(command.name)" : "/\(command.name)")
                                .font(.kore(13, .medium))
                                .foregroundStyle(Theme.text)
                            if !command.hint.isEmpty {
                                Text(command.hint)
                                    .font(.kore(12))
                                    .foregroundStyle(Theme.tertiary)
                            }
                            Spacer(minLength: 12)
                            Text(command.description)
                                .font(.kore(12))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(index == selected ? Theme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                        .onTapGesture { accept(command) }
                        .id(command.id)
                    }
                }
                .padding(4)
            }
            .onChange(of: selected) { proxy.scrollTo(matches[selected].id) }
        }
        .frame(maxHeight: 260)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var modelMenu: some View {
        Menu {
            Section("Model") {
                ForEach(chat.models) { option in
                    Button {
                        chat.setModel(option)
                    } label: {
                        if option.id == chat.modelId {
                            Label(option.name, systemImage: "checkmark")
                        } else {
                            Text(option.name)
                        }
                    }
                }
            }
            if let efforts = chat.currentModel?.efforts, !efforts.isEmpty {
                Section("Effort") {
                    ForEach(efforts, id: \.self) { level in
                        Button {
                            chat.setEffort(level)
                        } label: {
                            if level == chat.effort {
                                Label(Self.effortName(level), systemImage: "checkmark")
                            } else {
                                Text(Self.effortName(level))
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(chat.modelLabel)
                    .font(.kore(12, .medium))
                    .foregroundStyle(Theme.text)
                if let effort = chat.effortLabel {
                    Text(effort)
                        .font(.kore(12))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.surfaceHover, in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var modeMenu: some View {
        Menu {
            ForEach(chat.availableModes) { mode in
                modeToggle(mode, isOn: chat.mode == mode.id) { chat.setMode(mode.id) }
            }
            if chat.provider == .codex {
                Divider()
                modeToggle(Provider.codexPlan, isOn: chat.planMode) { chat.setPlanMode(!chat.planMode) }
            }
        } label: {
            let mode = chat.provider == .codex ? chat.permissionsMode : chat.activeMode
            HStack(spacing: 3) {
                ModeIcon(mode: mode)
                Text(mode.label).font(.kore(12, mode.tint == nil ? .regular : .medium))
            }
            .foregroundStyle(mode.tint ?? Theme.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Shift+Tab to switch")
    }

    private func modeToggle(_ mode: ModeOption, isOn: Bool, action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in action() })) {
            Label {
                Text(mode.label)
            } icon: {
                Image(nsImage: ModeIcons.image(mode.icon))
            }
        }
    }

    private static func effortName(_ level: String) -> String {
        level == "xhigh" ? "Extra high" : level.capitalized
    }

    // MARK: Image viewer

    private func view(_ attachment: Attachment, pending: Bool) {
        viewer.value = ImageEditor(attachment, pending: pending)
        composerFocused = false
    }

    /// A composer image takes its markup in place; a sent image (marked up or not) is added to
    /// the next message.
    private func finishViewing(_ editor: ImageEditor) {
        if let id = editor.pendingID {
            if !editor.strokes.isEmpty, let url = editor.render() { chat.replaceAttachment(id, with: url) }
        } else if let url = editor.strokes.isEmpty ? (editor.url ?? editor.render()) : editor.render() {
            chat.attach([url])
        }
        closeViewer()
    }

    private func closeViewer() {
        viewer.value = nil
        composerFocused = true
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = chat.folder
        if panel.runModal() == .OK { chat.attach(panel.urls) }
        composerFocused = true
    }
}

// MARK: - Transcript

private struct EntryView: View {
    let entry: ChatModel.Entry
    let openImage: (Attachment) -> Void

    var body: some View {
        switch entry.kind {
        case .user:
            VStack(alignment: .leading, spacing: 8) {
                if !entry.attachments.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(entry.attachments) { attachment in
                            AttachmentChip(attachment: attachment, open: { openImage(attachment) })
                        }
                    }
                }
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .font(Theme.body)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        case .assistant:
            Text(markdown(entry.text))
                .font(Theme.body)
                .foregroundStyle(Theme.text)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .plan:
            PlanText(text: entry.text)
        case .thinking:
            Text(entry.text)
                .font(Theme.body)
                .italic()
                .foregroundStyle(Theme.tertiary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            ToolRow(entry: entry)
        case .notice:
            Text(entry.text)
                .font(.kore(12))
                .foregroundStyle(entry.isError ? Theme.danger : Theme.tertiary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: entry.isError ? .leading : .center)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct ToolRow: View {
    let entry: ChatModel.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(entry.done ? Theme.text.opacity(0.7) : Theme.secondary)
                    .frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(entry.toolName ?? "Tool")
                    .font(.kore(12, .semibold))
                    .foregroundStyle(Theme.text)
                Text(entry.text)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if entry.done, let result = entry.result {
                let firstLine = result.split(separator: "\n").first.map(String.init) ?? "(no output)"
                Text(firstLine)
                    .font(Theme.mono)
                    .foregroundStyle(entry.isError ? Theme.danger : Theme.tertiary)
                    .lineLimit(1)
                    .padding(.leading, 14)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Approvals

private struct PermissionCard: View {
    let approval: ChatModel.Approval
    let decide: (ChatModel.Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(approval.title)
                .font(.kore(13, .semibold))
                .foregroundStyle(Theme.text)
            if let detail = approval.detail {
                Text(detail)
                    .font(.kore(12))
                    .foregroundStyle(Theme.secondary)
            }
            if let body = approval.body {
                Text(body)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Deny") { decide(.deny) }
                    .buttonStyle(SubtleButtonStyle())
                if approval.canAlwaysAllow {
                    Button("Always allow") { decide(.allowAlways) }
                        .buttonStyle(SubtleButtonStyle())
                }
                Button("Allow") { decide(.allow) }
                    .buttonStyle(SubtleButtonStyle(prominent: true))
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }
}

/// Pick one option per question; submits once every question is answered.
private struct QuestionCard: View {
    let approval: ChatModel.Approval
    let submit: ([String: String]) -> Void
    @StateObject private var picked = Local([String: String]())

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(approval.questions, id: \.id) { question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.text)
                        .font(.kore(13, .semibold))
                        .foregroundStyle(Theme.text)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                            Button {
                                picked.value[question.id] = option.label
                                if approval.questions.allSatisfy({ picked.value[$0.id] != nil }) {
                                    submit(picked.value)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).font(.kore(13, .medium))
                                    if !option.description.isEmpty {
                                        Text(option.description).font(.kore(11)).opacity(0.7)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(SubtleButtonStyle(prominent: picked.value[question.id] == option.label))
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }
}

// MARK: - Modes

/// A plan, marked in the plan-mode color.
private struct PlanText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plan")
                .font(.kore(11, .semibold))
                .foregroundStyle(ModeOption.teal)
            Text(planMarkdown(text))
                .font(Theme.body)
                .foregroundStyle(Theme.text)
                .lineSpacing(3)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ModeOption.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ModeOption.teal.opacity(0.3)))
    }
}

private func planMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}

/// Claude Code's exit-plan prompt.
private struct PlanApprovalCard: View {
    let plan: String
    let decide: (ChatModel.Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ready to code?")
                .font(.kore(13, .semibold))
                .foregroundStyle(Theme.text)
            ScrollView {
                Text(planMarkdown(plan))
                    .font(Theme.body)
                    .foregroundStyle(Theme.text)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 8) {
                Spacer()
                Button("No, keep planning") { decide(.keepPlanning) }
                    .buttonStyle(SubtleButtonStyle())
                Button("Yes, manually approve edits") { decide(.approvePlan(autoAcceptEdits: false)) }
                    .buttonStyle(SubtleButtonStyle())
                Button("Yes, auto-accept edits") { decide(.approvePlan(autoAcceptEdits: true)) }
                    .buttonStyle(SubtleButtonStyle(prominent: true))
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ModeOption.teal.opacity(0.45)))
    }
}

/// The Codex CLI's prompt after a plan is proposed in Plan mode.
private struct ImplementPlanCard: View {
    let implement: () -> Void
    let stay: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Implement this plan?")
                .font(.kore(13, .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            Button("No, stay in Plan mode", action: stay)
                .buttonStyle(SubtleButtonStyle())
            Button("Yes, implement this plan", action: implement)
                .buttonStyle(SubtleButtonStyle(prominent: true))
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ModeOption.teal.opacity(0.45)))
    }
}

/// Codex extension's Plan indicator: lightbulb + "Plan"; hover shows × to turn it off.
private struct PlanChip: View {
    let turnOff: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: turnOff) {
            HStack(spacing: 5) {
                if hovered.value {
                    Image(systemName: "xmark.circle.fill").font(.kore(12))
                } else {
                    ModeIcon(mode: Provider.codexPlan)
                }
                Text("Plan").font(.kore(12, .medium))
            }
            .foregroundStyle(ModeOption.teal)
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help("Turn off Plan mode")
    }
}

// MARK: - Attachments

/// An attached image (thumbnail, click to view) or file (icon + name); removable while still
/// in the composer.
private struct AttachmentChip: View {
    let attachment: Attachment
    var open: (() -> Void)?
    var remove: (() -> Void)?

    var body: some View {
        Group {
            if let thumbnail = attachment.thumbnail {
                Button {
                    open?()
                } label: {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(attachment.name)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.kore(12))
                        .foregroundStyle(Theme.secondary)
                    Text(attachment.name)
                        .font(.kore(12))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.surfaceHover, in: RoundedRectangle(cornerRadius: 7))
                .help(attachment.url?.path ?? attachment.name)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text, Theme.surfaceHover)
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .help("Remove")
            }
        }
    }

    private var icon: String {
        switch attachment.kind {
        case .image: "photo"
        case .text: "doc.text"
        case .pdf: "doc.richtext"
        case .other: attachment.url?.hasDirectoryPath == true ? "folder" : "doc"
        }
    }
}

/// Hands over the hosting NSWindow, so key handling can be limited to this window.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Reader(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Reader: NSView {
        let onWindow: (NSWindow?) -> Void

        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }
    }
}
