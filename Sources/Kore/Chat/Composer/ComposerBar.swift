import SwiftUI

/// The row under the text field: + · / · context wheel · model … mode · send. In a narrow tile
/// it steps down ("Compacting…", then effort, then labels, then the model pill go) instead of
/// clipping.
struct ComposerBar: View {
    let chat: Chat
    let attach: () -> Void
    let slash: () -> Void
    @StateObject private var plusHovered = Local(false)

    var body: some View {
        HStack(spacing: Space.xxl) {
            Button(action: attach) {
                Image(systemName: "plus")
                    .font(Glyph.attach)
                    .foregroundStyle(plusHovered.value ? Theme.text : Theme.secondary)
            }
            .buttonStyle(.plain)
            .onHover { plusHovered.value = $0 }
            .help("Attach files and images")

            Button(action: slash) {
                Text("/")
                    .font(Glyph.slash)
                    .foregroundStyle(Theme.secondary)
                    .frame(width: Size.slashGlyph, height: Size.slashGlyph)
                    .overlay(RoundedRectangle(cornerRadius: Radius.glyph).stroke(Theme.secondary, lineWidth: Size.slashStroke))
            }
            .buttonStyle(.plain)
            .help("Slash commands")

            // The slot is kept once there's a session, so the bar doesn't shift when usage arrives.
            if chat.status.sessionId != nil {
                ContextWheel(chat: chat)
                    .padding(.horizontal, -Space.sm)
            }

            ViewThatFits(in: .horizontal) {
                if chat.context.compacting { controls(.full, compacting: true) }
                controls(.full)
                controls(.noEffort)
                controls(.iconsOnly)
                controls(.minimal)
            }

            sendButton
        }
        .padding(Inset.composerBar)
    }

    private enum Density { case full, noEffort, iconsOnly, minimal }

    private func controls(_ density: Density, compacting: Bool = false) -> some View {
        HStack(spacing: Space.xxl) {
            if compacting {
                Text("Compacting…").font(Chrome.caption).foregroundStyle(Theme.secondary).lineLimit(1).fixedSize()
                    .padding(.leading, -Space.sm)
            }
            if !chat.controls.models.isEmpty && density != .minimal {
                ModelMenu(chat: chat, showEffort: density == .full)
            }
            Spacer(minLength: 0)
            if let plan = chat.provider.planToggle, chat.controls.planMode {
                PlanChip(mode: plan) { chat.setPlanMode(false) }
            }
            ModeMenu(chat: chat, showLabel: density == .full || density == .noEffort)
        }
    }

    private var sendButton: some View {
        Button {
            chat.status.isRunning ? chat.stop() : chat.send()
        } label: {
            Image(systemName: chat.status.isRunning ? "stop.fill" : "arrow.up")
                .font(Glyph.send)
                .foregroundStyle(Theme.background)
                .frame(width: Size.iconButton, height: Size.iconButton)
                .background(Theme.text, in: RoundedRectangle(cornerRadius: Radius.chip))
        }
        .buttonStyle(.plain)
        .disabled(!chat.status.isRunning && !chat.canSend)
        .opacity(!chat.status.isRunning && !chat.canSend ? 0.3 : 1)
    }
}

/// Model and effort, from the CLI's own list.
struct ModelMenu: View {
    let chat: Chat
    var showEffort = true

    var body: some View {
        Menu {
            Section("Model") {
                ForEach(chat.controls.models) { option in
                    Button {
                        chat.setModel(option)
                    } label: {
                        if option.id == chat.controls.modelId {
                            Label(option.name, systemImage: "checkmark")
                        } else {
                            Text(option.name)
                        }
                    }
                }
            }
            if let efforts = chat.controls.currentModel?.efforts, !efforts.isEmpty {
                Section("Effort") {
                    ForEach(efforts, id: \.self) { level in
                        Button {
                            chat.setEffort(level)
                        } label: {
                            if level == chat.controls.effort {
                                Label(Self.effortName(level), systemImage: "checkmark")
                            } else {
                                Text(Self.effortName(level))
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Space.sm) {
                Text(chat.controls.modelLabel)
                    .font(TextStyle.labelMedium)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if showEffort, let effort = chat.controls.effortLabel {
                    Text(effort)
                        .font(TextStyle.label)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.xs)
            .background(Theme.surfaceHover, in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(chat.controls.effortLabel.map { "\(chat.controls.modelLabel) · \($0)" } ?? chat.controls.modelLabel)
    }

    static func effortName(_ level: String) -> String {
        level == "xhigh" ? "Extra high" : level.capitalized
    }
}

/// The provider's modes (icon + label), as in its VS Code extension.
struct ModeMenu: View {
    let chat: Chat
    var showLabel = true

    var body: some View {
        Menu {
            ForEach(chat.controls.availableModes) { mode in
                toggle(mode, isOn: chat.controls.mode == mode.id) { chat.setMode(mode.id) }
            }
            if let plan = chat.provider.planToggle {
                Divider()
                toggle(plan, isOn: chat.controls.planMode) { chat.setPlanMode(!chat.controls.planMode) }
            }
        } label: {
            // A plan toggle shows as its own chip, so the menu keeps the permissions mode.
            let mode = chat.provider.planToggle != nil ? chat.controls.permissionsMode : chat.controls.activeMode
            HStack(spacing: Space.xs) {
                ModeIcon(mode: mode)
                if showLabel {
                    Text(mode.label).font(mode.tint == nil ? TextStyle.label : TextStyle.labelMedium).lineLimit(1)
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
