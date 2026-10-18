import AppKit
import KoreCore
import SwiftUI
import UniformTypeIdentifiers

/// "Import a chat", one tertiary line at the composer's leading edge, just above it, while the
/// chat has no message (chat-handoff.html §1 A). On hover the words take the text colour on the
/// tool-hover fill. While a chat file is dragged over the empty chat it reads "Drop to import",
/// in accent. It hides (keeping its place) under the open picker, which opens where it is.
struct ImportLine: View {
    let state: ImportState
    let open: @MainActor @Sendable () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        let target = state.dropTarget
        Button(action: open) {
            HStack(spacing: Space.sm) {
                Image(systemName: "tray.and.arrow.down")
                Text(target ? "Drop to import" : "Import a chat")
            }
            .font(Chrome.label)
            .foregroundStyle(target ? Theme.accent : hovered.value ? Theme.text : Theme.tertiary)
            .padding(.horizontal, Space.sm)
            .frame(height: Size.importLine)
            .background(
                target ? Theme.commandFill : hovered.value ? Theme.toolHover : .clear, in: RoundedRectangle(cornerRadius: Radius.chip)
            )
            .overlay {
                if target { RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Theme.accentLine, lineWidth: Stroke.hairline) }
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.chip))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help("Import a chat from another agent or a .jsonl file")
        .storyID(StoryID.Composer.importLine, press: open)
        .opacity(state.isOpen ? 0 : 1)
        .allowsHitTesting(!state.isOpen)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The empty chat's transcript area as a drop target for chat files. A file Kore knows (by its
/// first lines) lights the line and, dropped, opens the picker with it picked; anything else
/// is refused before it lands, so nothing lights, the cursor shows no "+", and the system slides
/// it back. Drops on the composer still attach, as before.
struct ImportDrop: DropDelegate {
    let state: ImportState
    /// The chat is empty and can import; otherwise the area takes no drops, as before.
    let offered: Bool
    let dropped: (URL) -> Void

    func validateDrop(info: DropInfo) -> Bool { offered && Self.draggedChat() != nil }

    func dropEntered(info: DropInfo) { state.dropTarget = validateDrop(info: info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .copy : .forbidden)
    }

    func dropExited(info: DropInfo) { state.dropTarget = false }

    func performDrop(info: DropInfo) -> Bool {
        state.dropTarget = false
        guard offered, let file = Self.draggedChat() else { return false }
        dropped(file)
        return true
    }

    /// The dragged file, when it's one chat file a format knows: read from the drag pasteboard
    /// as it's asked, which a drop's item providers can't do in time (each file's answer is kept).
    static func draggedChat() -> URL? {
        let urls = NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard let urls, urls.count == 1, HandoffFormats.identify(urls[0], quick: true) != nil else { return nil }
        return urls[0]
    }
}

/// Choose file…: the system's open panel on `.jsonl` files, where files no format knows are
/// greyed and can't be picked. It starts in another agent's own store. A storyline host is
/// asked instead (`StorylineSeams.chooseFile`).
@MainActor
enum ImportFilePanel {
    static func choose(for provider: Provider, in window: NSWindow?, picked: @escaping (URL) -> Void) {
        if StoryHost.installed {
            if let url = StorylineSeams.chooseFile?() { picked(url) }
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        let filter = ChatFileFilter()
        panel.delegate = filter
        let store = HandoffFormats.all.first { $0.id != provider.id }?.store
        if let store, FileManager.default.fileExists(atPath: store.path) { panel.directoryURL = store }
        let done: (NSApplication.ModalResponse) -> Void = { response in
            withExtendedLifetime(filter) {
                if response == .OK, let url = panel.url { picked(url) }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }
}

/// Greys files no format knows (the quick sniff; folders stay open).
private final class ChatFileFilter: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return true }
        return HandoffFormats.identify(url, quick: true) != nil
    }
}
