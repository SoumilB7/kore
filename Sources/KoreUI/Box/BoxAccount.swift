import AppKit
import HostClient
import src
import SwiftUI

/// The Account popup in a box's window: who the chat's CLI is signed in as on the box, and
/// GitHub's line under it. A sign-in runs on the box; its page opens in this Mac's browser, and
/// the token stays on the box.
struct BoxAccountLines: View {
    let chat: Chat
    let connection: HostConnection

    var body: some View {
        let accounts = connection.accounts
        VStack(alignment: .leading, spacing: Space.sm) {
            BoxAccountLine(
                title: "\(chat.provider.usage.product) on \(connection.alias)", key: chat.provider.id, accounts: accounts,
                takesPaste: chat.provider.id == "claude"
            ) { accounts.signIn(chat.provider.id) }
            BoxAccountLine(title: "GitHub on \(connection.alias)", key: BoxAccounts.gitHub, accounts: accounts, takesPaste: false) {
                accounts.signInGitHub()
            }
        }
        .task { await accounts.refresh(chat.provider.id) }
    }
}

/// One login: its name and what the box says, Sign in; while it runs, the page to open, its code,
/// and (Claude) the field for the code the page shows.
struct BoxAccountLine: View {
    let title: String
    let key: String
    let accounts: BoxAccounts
    let takesPaste: Bool
    let signIn: () -> Void
    @StateObject private var code = Local("")
    @StateObject private var copied = Local(false)
    @FocusState private var typing: Bool

    var body: some View {
        let line = accounts.line(key)
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                Text(title).font(TextStyle.labelMedium).foregroundStyle(Theme.text).lineLimit(1)
                Text(status(line)).font(TextStyle.caption).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: Space.sm)
                switch line.step {
                // Signed in already: nothing to press.
                case .idle where line.signedIn == true: EmptyView()
                case .idle, .failed: Button("Sign in", action: signIn).smallButton()
                case .starting: ProgressView().controlSize(.small)
                case .waiting, .submitting: Button("Cancel") { accounts.cancel(key) }.smallButton()
                }
            }
            if let page = page(line.step) {
                HStack(spacing: Space.sm) {
                    if let url = page.url { Button("Open page") { NSWorkspace.shared.open(url) }.smallButton(prominent: true) }
                    if let device = page.code {
                        Text(device).font(TextStyle.code).foregroundStyle(Theme.text).textSelection(.enabled)
                        Button(copied.value ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(device, forType: .string)
                            copied.value = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                copied.value = false
                            }
                        }
                        .smallButton()
                    }
                    if takesPaste {
                        TextField("", text: $code.value, prompt: Text("Code from the page").foregroundStyle(Theme.tertiary))
                            .textFieldStyle(.plain)
                            .focused($typing)
                            .fieldWell(focused: typing)
                            .onSubmit(submit)
                            .onAppear { typing = true }
                        Button("Sign in", action: submit).smallButton(prominent: true).disabled(code.value.isEmpty)
                    }
                }
            }
        }
    }

    private func submit() {
        accounts.submit(key, code: code.value.trimmingCharacters(in: .whitespacesAndNewlines))
        code.value = ""
    }

    private func page(_ step: BoxAccounts.Step) -> HostWire.Page? {
        switch step {
        case .waiting(let page), .submitting(let page): page
        default: nil
        }
    }

    private func status(_ line: BoxAccounts.Line) -> String {
        if case .failed(let why) = line.step { return why }
        return line.said ?? ""
    }
}
