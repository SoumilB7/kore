import AppKit
import HostClient
import SwiftUI

/// Add folder…'s field under a box, in the box popup: a path (there's
/// no Finder for a box) with one line under it. A folder already on the box is added to what it
/// serves and handed to `added`; nothing opens. Esc or `close` puts the row back.
struct BoxAddFolderField: View {
    let alias: String
    let close: () -> Void
    let added: (BoxFolder) -> Void
    @StateObject private var path = Local("")
    @StateObject private var failed = Local<String?>(nil)
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            TextField("", text: Binding(get: { path.value }, set: { path.value = $0; failed.value = nil }), prompt: Text("~/Code/project").foregroundStyle(Theme.tertiary))
                .textFieldStyle(.plain)
                .font(Chrome.label)
                .focused($focused)
                .fieldWell(focused: focused)
                .onSubmit(submit)
                .onExitCommand(perform: close)
                .onAppear { focused = true }
            Text(failed.value ?? "A folder already on \(NodeNames.name(alias))")
                .font(Chrome.caption)
                .foregroundStyle(failed.value == nil ? Theme.tertiary : Theme.danger)
        }
        .padding(.vertical, Space.xs)
    }

    private func submit() {
        let typed = path.value.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        Task {
            switch await BoxList.shared.addFolder(alias, path: typed) {
            case .success(let folder): added(folder)
            case .failure(let refusal): failed.value = refusal.message
            }
        }
    }
}

/// A box folder row's window glyphs: ⧉ opens it in a new window; ↵ opens it here, only while this
/// window is a lone empty tab (or the new window), which then gives way.
struct BoxFolderGlyphs: View {
    let place: BoxPlace
    /// This window can give way to the folder's.
    let here: NSWindow?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: Space.xxs) {
            if let here {
                glyph("return", help: "Open here") {
                    openWindow(value: place)
                    here.close()
                }
            }
            glyph("macwindow.badge.plus", help: "Open in new window") { openWindow(value: place) }
        }
    }

    private func glyph(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        IconButton(symbol: symbol, kind: .mini, font: Chrome.caption, help: help, action: action)
    }
}

extension Workspace {
    /// Its window, while it's a lone empty tab: a box folder may open in its place.
    var givesWay: NSWindow? { tabs.count == 1 && tabs[0].isEmpty ? window : nil }
}
