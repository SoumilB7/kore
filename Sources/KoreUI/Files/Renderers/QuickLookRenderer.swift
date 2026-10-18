import AppKit
import Quartz
import SwiftUI

/// Office and iWork documents (and RTF) through Quick Look, as Finder's preview shows them:
/// spreadsheets with their sheets, documents and slides paged. Quick Look draws them out of
/// process, so a large workbook costs this app little.
struct QuickLookFileView: View {
    let file: FileInfo
    let context: RendererContext

    var body: some View {
        QuickLookHost(url: file.url, reloadToken: context.reloadToken)
            .background(Theme.background)
            .onAppear {
                context.setFacts([file.type?.localizedDescription, FileEditorView.size(Int(file.size))].compactMap { $0 })
            }
    }

    /// What Quick Look opens here (the plan's Office and iWork list).
    static let extensions: Set<String> = ["xlsx", "xls", "docx", "doc", "pptx", "ppt", "numbers", "pages", "key", "rtf"]
}

private struct QuickLookHost: NSViewRepresentable {
    let url: URL
    let reloadToken: Int

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.shouldCloseWithWindow = true
        view.autostarts = false
        view.previewItem = url as NSURL
        // Quick Look draws out of process; this times Kore's part.
        RenderTiming.ready(QuickLookRenderer.id)
        context.coordinator.token = reloadToken
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard context.coordinator.token != reloadToken else { return }
        context.coordinator.token = reloadToken
        view.refreshPreviewItem()
    }

    /// Leaving the screen ends the preview (and its helper's work).
    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var token = 0
    }
}

enum QuickLookRenderer: FileRenderer {
    static let id = "quicklook"
    static let hasRaw = false

    static func matches(_ file: FileInfo) -> Bool { QuickLookFileView.extensions.contains(file.ext) }

    static func makeView(_ file: FileInfo, context: RendererContext) -> AnyView {
        AnyView(QuickLookFileView(file: file, context: context))
    }
}
