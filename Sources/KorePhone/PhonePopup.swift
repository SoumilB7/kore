import KoreRemote
import KoreUI
import SwiftUI

/// "/" → Phone: the switch, the phones, pairing, and what they did.
struct PhonePopup: View {
    let chat: Chat
    let room: CGFloat
    let host: RemoteHost
    let model: PhoneModel
    @StateObject private var typed = Box("")

    var body: some View {
        ModulePopup(
            chat: chat, id: PhoneUI.popupID, room: room, isOpen: { model.openIn == chat.id }, close: { model.openIn = nil },
            editing: { if case .typing = model.pairing { true } else { false } }
        ) {
            VStack(alignment: .leading, spacing: ModuleStyle.md) {
                header
                switch model.pairing {
                case .code(let text, let until): PairCode(text: text, until: until) { host.service.cancelPairing() }
                case .typing(let prompt, let wrong): typing(prompt, wrong: wrong)
                case .failed(let why):
                    Text(why).font(ModuleStyle.label).foregroundStyle(ModuleStyle.secondary)
                    phones
                case .none:
                    if model.showingActivity { activity } else if model.showingRelay { RelaySees { model.showingRelay = false } } else { phones }
                }
            }
            .padding(ModuleStyle.row)
        }
    }

    private var header: some View {
        HStack(spacing: ModuleStyle.sm) {
            Text("Phone").font(ModuleStyle.title).foregroundStyle(ModuleStyle.text)
            Spacer()
            Toggle("", isOn: Binding(get: { model.isOn }, set: { $0 ? host.service.enable() : host.service.disable() }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .moduleStoryID(PhoneUI.switchID)
        }
    }

    @ViewBuilder private var phones: some View {
        if model.isOn {
            if model.rows.isEmpty {
                Text("No phones paired").font(ModuleStyle.label).foregroundStyle(ModuleStyle.tertiary)
            }
            ForEach(model.rows) { row in PhoneRow(row: row, host: host) }
            HStack(spacing: ModuleStyle.sm) {
                Text(relayLine).font(ModuleStyle.caption).foregroundStyle(ModuleStyle.tertiary)
                Button("What the relay sees") { model.showingRelay = true }.buttonStyle(.link).font(ModuleStyle.caption)
                    .moduleStoryID(PhoneUI.relayID)
            }
            HStack {
                Button("Activity") { model.showingActivity = true }.buttonStyle(.link).font(ModuleStyle.caption)
                    .moduleStoryID(PhoneUI.activityID)
                Spacer()
                Button("Pair a phone") { host.service.startPairing() }
                    .moduleButton(prominent: model.rows.isEmpty)
                    .disabled(model.relay != .connected || model.rows.count >= RemoteGate.maxPhones)
                    .moduleStoryID(PhoneUI.pairID)
            }
        } else if model.relay == .notSetUp {
            Text("The relay isn't set up yet.").font(ModuleStyle.label).foregroundStyle(ModuleStyle.tertiary)
        } else {
            Text("Off. While it's off, Kore keeps no mailbox on the relay and no phone can reach it.").font(ModuleStyle.label)
                .foregroundStyle(ModuleStyle.tertiary)
        }
    }

    private var relayLine: String {
        switch model.relay {
        case .connected: "Relay · connected"
        case .connecting: "Relay · connecting…"
        case .offline(let why): "Relay · offline: \(why)"
        case .notSetUp: "Relay · not set up"
        case .off: "Relay · off"
        }
    }

    private func typing(_ prompt: PairPrompt, wrong: Bool) -> some View {
        VStack(alignment: .leading, spacing: ModuleStyle.sm) {
            Text("A phone says it's “\(prompt.claimedName)”").font(ModuleStyle.bodyMedium).foregroundStyle(ModuleStyle.text)
            Text(wrong ? "That's not it. \(prompt.triesLeft) left." : "Type the code on its screen").font(ModuleStyle.label)
                .foregroundStyle(wrong ? ModuleStyle.danger : ModuleStyle.secondary)
            TextField("000000", text: $typed.value)
                .font(ModuleStyle.digits).textFieldStyle(.plain)
                .onChange(of: typed.value) { _, new in typed.value = String(new.filter(\.isNumber).prefix(6)) }
                .onSubmit { if typed.value.count == 6 { submit() } }
                .moduleStoryID(PhoneUI.codeFieldID)
            HStack {
                Spacer()
                Button("Deny") { host.service.denyPairing() }.moduleButton().moduleStoryID(PhoneUI.denyID)
                Button("Allow") { submit() }.moduleButton(prominent: true).disabled(typed.value.count != 6).moduleStoryID(PhoneUI.allowID)
            }
        }
    }

    private func submit() {
        host.service.submitCode(typed.value)
        typed.value = ""
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: ModuleStyle.xs) {
            HStack {
                Text("Activity").font(ModuleStyle.labelMedium).foregroundStyle(ModuleStyle.secondary)
                Spacer()
                Button("Back") { model.showingActivity = false }.buttonStyle(.link).font(ModuleStyle.caption)
            }
            if model.activity.isEmpty {
                Text("Nothing yet this run").font(ModuleStyle.label).foregroundStyle(ModuleStyle.tertiary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: ModuleStyle.xs) {
                    ForEach(model.activity) { item in
                        Text("\(item.at.formatted(date: .omitted, time: .shortened))  \(item.phone.map { $0 + " · " } ?? "")\(item.text)")
                            .font(ModuleStyle.code).foregroundStyle(ModuleStyle.secondary).lineLimit(1)
                    }
                }
            }
        }
    }
}
