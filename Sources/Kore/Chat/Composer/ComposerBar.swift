import SwiftUI

/// The row under the text field: + · / · model … mode · send. In a narrow tile it steps down
/// (effort, then labels, then the model pill go) instead of clipping.
struct ComposerBar: View {
    let chat: ChatModel
    let attach: () -> Void
    let slash: () -> Void
    @StateObject private var plusHovered = Local(false)

    var body: some View {
        HStack(spacing: 14) {
            Button(action: attach) {
                Image(systemName: "plus")
                    .font(.kore(14))
                    .foregroundStyle(plusHovered.value ? Theme.text : Theme.secondary)
            }
            .buttonStyle(.plain)
            .onHover { plusHovered.value = $0 }
            .help("Attach files and images")

            Button(action: slash) {
                Text("/")
                    .font(.kore(11, .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 16, height: 16)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.secondary, lineWidth: 1.2))
            }
            .buttonStyle(.plain)
            .help("Slash commands")

            ViewThatFits(in: .horizontal) {
                controls(.full)
                controls(.noEffort)
                controls(.iconsOnly)
                controls(.minimal)
            }

            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private enum Density { case full, noEffort, iconsOnly, minimal }

    private func controls(_ density: Density) -> some View {
        HStack(spacing: 14) {
            if !chat.models.isEmpty && density != .minimal {
                ModelMenu(chat: chat, showEffort: density == .full)
            }
            Spacer(minLength: 0)
            if chat.provider == .codex && chat.planMode {
                PlanChip { chat.setPlanMode(false) }
            }
            ModeMenu(chat: chat, showLabel: density == .full || density == .noEffort)
        }
    }

    private var sendButton: some View {
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
}

/// Model and effort, from the CLI's own list.
struct ModelMenu: View {
    let chat: ChatModel
    var showEffort = true

    var body: some View {
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
                    .lineLimit(1)
                if showEffort, let effort = chat.effortLabel {
                    Text(effort)
                        .font(.kore(12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
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
        .help(chat.effortLabel.map { "\(chat.modelLabel) · \($0)" } ?? chat.modelLabel)
    }

    static func effortName(_ level: String) -> String {
        level == "xhigh" ? "Extra high" : level.capitalized
    }
}

/// The provider's modes (icon + label), as in its VS Code extension.
struct ModeMenu: View {
    let chat: ChatModel
    var showLabel = true

    var body: some View {
        Menu {
            ForEach(chat.availableModes) { mode in
                toggle(mode, isOn: chat.mode == mode.id) { chat.setMode(mode.id) }
            }
            if chat.provider == .codex {
                Divider()
                toggle(Provider.codexPlan, isOn: chat.planMode) { chat.setPlanMode(!chat.planMode) }
            }
        } label: {
            let mode = chat.provider == .codex ? chat.permissionsMode : chat.activeMode
            HStack(spacing: 3) {
                ModeIcon(mode: mode)
                if showLabel {
                    Text(mode.label).font(.kore(12, mode.tint == nil ? .regular : .medium)).lineLimit(1)
                }
            }
            .foregroundStyle(mode.tint ?? Theme.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Shift+Tab to switch")
    }

    private func toggle(_ mode: ModeOption, isOn: Bool, action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in action() })) {
            Label {
                Text(mode.label)
            } icon: {
                Image(nsImage: ModeIcons.image(mode.icon))
            }
        }
    }
}
