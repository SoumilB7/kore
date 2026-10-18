import AppKit
import SwiftUI

/// KORE_GALLERY=1: a window showing every approval card and composer chip with fixed sample
/// content, so their look can be snapshotted and compared without a live CLI. The transcript's
/// items are in `DevTimelineGallery` (KORE_GALLERY=timeline).
@MainActor
enum DevGallery {
    static func showIfRequested() {
        if DevTimelineGallery.showIfRequested() { return }
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
