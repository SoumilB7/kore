import SwiftUI

/// One chat: the transcript above, approval cards and the composer below, overlays on top.
/// Each part is its own view reading only its own state, so typing re-renders the composer
/// alone and a streamed token re-renders one row.
struct ChatView: View {
    let chat: ChatModel
    @FocusState private var composerFocused: Bool
    @StateObject private var viewer = Local<ImageEditor?>(nil)

    var body: some View {
        VStack(spacing: 0) {
            TranscriptView(chat: chat) { view($0, pending: false) }
            VStack(spacing: 10) {
                ApprovalsView(chat: chat)
                ComposerView(chat: chat, focused: $composerFocused) { view($0, pending: true) }
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
        .animation(.easeOut(duration: 0.15), value: viewer.value?.id)
        .onAppear {
            composerFocused = true
            if DevSnapshot.viewImage, let first = chat.attachments.first { view(first, pending: true) }
        }
        .task { await chat.start() }
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
}
