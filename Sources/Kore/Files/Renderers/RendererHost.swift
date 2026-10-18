import SwiftUI

/// A file tab's content: the file's renderer when one matches and the tab isn't showing raw,
/// else `fallback` (the editor and its states). The fallback loads the text only when it
/// shows, so a rendered file is never also held as editor text.
struct RendererHost<Fallback: View>: View {
    let document: FileDocument
    let workspace: Workspace
    @ViewBuilder let fallback: () -> Fallback

    var body: some View {
        let rendering = document.rendering
        Group {
            if rendering.resolved != document.url {
                Color.clear
            } else if rendering.showsRenderer, let renderer = rendering.renderer, let info = rendering.info {
                renderer.makeView(info, context: context)
                    .id(renderer.id)
            } else {
                fallback().onAppear { document.loadIfNeeded() }
            }
        }
        .task(id: document.url) { await rendering.resolve(document.url) }
        // A file can grow from empty into a match, or change kind.
        .task(id: document.revision) { if document.revision > 0 { await rendering.refresh() } }
    }

    private var context: RendererContext {
        let workspace = workspace
        return RendererContext(
            reloadToken: document.revision, folder: workspace.folder,
            openURL: { workspace.openFile($0) }, zoom: Zoom.shared.scale)
    }
}

/// The path row's Raw ⇄ Rendered switch (VS Code's "Show Source" / "Open Preview"). Nothing
/// when the file's renderer has no raw form, or there's no renderer.
struct RendererToggle: View {
    let document: FileDocument

    var body: some View {
        let rendering = document.rendering
        if rendering.hasToggle {
            IconButton(
                symbol: rendering.showsRaw ? "doc.text.magnifyingglass" : "chevron.left.forwardslash.chevron.right",
                kind: .small, font: Chrome.label,
                help: rendering.showsRaw ? "Open Preview (⇧⌘V)" : "Show Source (⇧⌘V)"
            ) {
                rendering.showsRaw.toggle()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }
    }
}
