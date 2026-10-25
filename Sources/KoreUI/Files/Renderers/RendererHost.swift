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
        VStack(spacing: 0) {
            if rendering.resolved != document.url {
                Color.clear
            } else if rendering.showsRenderer, let renderer = rendering.renderer, let info = rendering.info {
                renderer.makeView(info, context: context)
                    .id(renderer.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !rendering.facts.isEmpty {
                    Rule()
                    RendererFacts(facts: rendering.facts)
                }
            } else {
                if let failure = rendering.failure {
                    RendererNotice(message: failure.reason, action: ("Show Preview", { rendering.showsRaw = false }))
                }
                fallback()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        document.loadIfNeeded()
                        if let line = rendering.failure?.line { goTo(line) }
                    }
            }
        }
        .task(id: document.url) { await rendering.resolve(document.url) }
        // A file can grow from empty into a match, or change kind.
        .task(id: document.revision) { if document.revision > 0 { await rendering.refresh() } }
    }

    private var context: RendererContext {
        let workspace = workspace
        let rendering = document.rendering
        let document = document
        let rendererID = rendering.renderer?.id
        return RendererContext(
            reloadToken: document.revision, folder: workspace.folder,
            openURL: { workspace.openFile($0, preview: true) }, zoom: Zoom.shared.scale, memory: rendering.memory,
            setFacts: { facts in if rendering.facts != facts { rendering.facts = facts } },
            failed: { reason, line in
                rendering.showsRaw = true
                rendering.failure = .init(reason: reason, line: line)
            },
            showSource: { rendering.showsRaw = true },
            openAsText: {
                rendering.showsRaw = true
                document.loadIfNeeded()
                document.openAnyway()
            },
            takeFocus: { [weak workspace, weak document, weak rendering] in
                guard let workspace, let document, let rendering,
                    workspace.activeFile === document, rendering.showsRenderer,
                    let rendererID, rendering.renderer?.id == rendererID,
                    rendering.resolved == document.url
                else { return false }
                defer { rendering.focusPending = false }
                return rendering.focusPending
            })
    }

    /// The caret on the line the parser stopped at, once the editor is in the window.
    private func goTo(_ line: Int) {
        let editor = document.editor
        DispatchQueue.main.async { editor.goTo(line: line) }
    }
}

/// The path row's Preview | Source switch. Nothing when the file's renderer has no raw form,
/// or there's no renderer.
struct RendererToggle: View {
    let document: FileDocument

    var body: some View {
        if document.rendering.hasToggle {
            PreviewSourceSwitch(rendering: document.rendering)
                .storyID(StoryID.Editor.rendererToggle, press: { document.rendering.showsRaw.toggle() })
        }
    }
}
