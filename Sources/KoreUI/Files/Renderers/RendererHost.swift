import LinkProtocol
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
            if document.box != nil, !document.loaded || document.preview == nil {
                // A box file: read over the link first. One no renderer can show (binary, gone)
                // is the editor's state.
                if document.loaded {
                    fallback().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear.onAppear { document.loadIfNeeded() }
                }
            } else if rendering.resolved != document.renderURL {
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
        .task(id: document.renderURL) { await rendering.resolve(document.renderURL) }
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
            openURL: { url in
                // A box file's link: the box file it names, in its tab.
                if document.box != nil {
                    if let path = Self.boxPath(url, near: document, in: workspace) { workspace.openBoxFile(path, preview: true) }
                    return
                }
                workspace.openFile(url, preview: true)
            }, zoom: Zoom.shared.scale, memory: rendering.memory,
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
                    rendering.resolved == document.renderURL
                else { return false }
                defer { rendering.focusPending = false }
                return rendering.focusPending
            },
            readNear: Self.boxReader(document, in: workspace))
    }

    /// A box file's renderer reads what it names over the link; nil for a file here.
    static func boxReader(_ document: FileDocument, in workspace: Workspace) -> (@MainActor (URL) async -> Data?)? {
        guard let box = document.box else { return nil }
        let read = box.read
        return { [weak workspace, weak document] (url: URL) async -> Data? in
            guard let workspace, let document, let path = boxPath(url, near: document, in: workspace) else { return nil }
            guard case .success(let file) = await read(path, nil) else { return nil }
            return file.image ?? file.text.map { Data($0.utf8) }
        }
    }

    /// The box path a renderer's URL names: beside the box file (its preview copy's folder, or
    /// its stand-in's), or a box path; nil outside the window's box folder.
    static func boxPath(_ url: URL, near document: FileDocument, in workspace: Workspace) -> String? {
        guard let file = document.box, let box = workspace.box else { return nil }
        let path = url.standardizedFileURL.path
        let folder = (file.path as NSString).deletingLastPathComponent
        let found: String
        if let copy = document.preview?.deletingLastPathComponent().standardizedFileURL.path, path.hasPrefix(copy + "/") {
            found = LinkFiles.normalised(folder + "/" + path.dropFirst(copy.count + 1))
        } else if path.hasPrefix(box.folderURL.standardizedFileURL.path + "/") {
            found = box.boxPath(url)
        } else {
            found = LinkFiles.normalised(path)
        }
        return found.hasPrefix(box.folder + "/") ? found : nil
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
