import AppKit
import SwiftUI

/// KORE_GALLERY=1: a window showing every transcript entry kind and approval card with fixed
/// sample content, so their look can be snapshotted and compared without a live CLI.
@MainActor
enum DevGallery {
    static func showIfRequested() {
        guard ProcessInfo.processInfo.environment["KORE_GALLERY"] == "1" else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 1640), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Gallery"
        window.contentView = NSHostingView(rootView: Gallery().environment(\.colorScheme, .dark))
        window.orderFront(nil)
        DevSnapshot.captureIfRequested()
    }
}

private struct Gallery: View {
    private func entry(_ kind: ChatModel.Entry.Kind, _ text: String, _ edit: (inout ChatModel.Entry) -> Void = { _ in }) -> ChatModel.Entry {
        var e = ChatModel.Entry(kind: kind, text: text)
        edit(&e)
        return e
    }

    private var entries: [ChatModel.Entry] {
        [
            entry(.user, "Split the composer into its own view, and keep typing fast in long chats."),
            entry(.thinking, "The draft lives in the same body as the transcript, so every keystroke rebuilds every row."),
            entry(.assistant, "I'll move the **composer** into `ComposerView` and make rows `Equatable`."),
            entry(.tool, "Sources/Kore/Chat/ChatView.swift") { $0.toolName = "Read"; $0.done = true; $0.result = "800 lines" },
            entry(.tool, "swift build") { $0.toolName = "Bash"; $0.done = true; $0.isError = true; $0.result = "error: cannot find 'Theme' in scope" },
            entry(.tool, "rg entries\\[") { $0.toolName = "Grep" },
            entry(.plan, "1. Split ChatView into Transcript, Composer and Approvals.\n2. Make rows **lazy** and `Equatable`."),
            entry(.peer, "Main is pushed; you can carry on in the main checkout.") { $0.from = "Kore" },
            entry(.notice, "Interrupted"),
            entry(.notice, "gpt-6.1-sol isn't available on this account") { $0.isError = true },
        ]
    }

    private let permission = Approval(
        id: "p", title: "Allow Bash?", detail: "List the folder", body: "ls -la Sources/Kore", canAlwaysAllow: true,
        questions: [])
    private let question = Approval(
        id: "q", title: "Question", detail: nil, body: nil, canAlwaysAllow: false,
        questions: [
            .init(id: "q1", text: "Which layout should the map use?", options: [
                .init(label: "Top to bottom", description: "Fits narrow tiles"),
                .init(label: "Left to right", description: "Like the extension's map"),
            ])
        ])

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(entries) { EntryView(entry: $0, openImage: { _ in }) }
            PermissionCard(approval: permission) { _ in }
            QuestionCard(approval: question) { _ in }
            PlanApprovalCard(plan: "Move the views onto tokens, then apply the snaps.") { _ in }
            ImplementPlanCard(implement: {}, stay: {})
            HStack(spacing: 8) {
                PlanChip(mode: CodexModes.plan) {}
                AttachmentChip(attachment: Attachment(name: "notes.md", kind: .text))
            }
        }
        .padding(24)
        .frame(width: 760, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
    }
}
