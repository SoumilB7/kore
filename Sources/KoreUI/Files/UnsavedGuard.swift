import AppKit
import SwiftUI

/// Asks before unsaved file edits are lost: closing a folder window (its close button, ⌘W)
/// or quitting. SwiftUI owns the window's delegate, so this sits in front of it and passes
/// everything else through.
@MainActor
final class UnsavedGuard: NSObject, NSWindowDelegate {
    /// Read from the Objective-C forwarding hooks, which AppKit calls on the main thread.
    nonisolated(unsafe) private weak var original: NSWindowDelegate?
    private weak var workspace: Workspace?
    private static var guards: [ObjectIdentifier: UnsavedGuard] = [:]

    static func install(on window: NSWindow, for workspace: Workspace) {
        let id = ObjectIdentifier(window)
        if let existing = guards[id], window.delegate === existing { return }
        let guarding = UnsavedGuard()
        guarding.original = window.delegate
        guarding.workspace = workspace
        guards[id] = guarding
        window.delegate = guarding
    }

    /// Answered yes once: the close it asked about goes through without asking again.
    private var answered = false
    /// A question about this close is up: a second ⌘W doesn't ask twice.
    private var asking = false

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let workspace, !answered {
            workspace.flushAutoSaves()
            let working = workspace.terminals.workingCount
            let files = workspace.unsavedFiles
            if working > 0 || !files.isEmpty {
                // Kore's own questions, over this window; it closes once they're answered.
                guard !asking else { return false }
                asking = true
                Task { @MainActor [weak self, weak sender] in
                    guard let self else { return }
                    var go = await TerminalPanel.confirm(working: working, in: sender)
                    if go { go = await Self.confirm({ workspace.unsavedFiles }, saveAll: workspace.saveAll, in: sender) }
                    self.asking = false
                    guard go, let sender else { return }
                    self.answered = true
                    sender.performClose(nil)
                    self.answered = false
                }
                return false
            }
        }
        return original?.windowShouldClose?(sender) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { Self.guards[ObjectIdentifier(window)] = nil }
        original?.windowWillClose?(notification)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }

    /// Save all, cancel, or discard the files unsaved when its turn comes (a tab's own question
    /// before it may have settled one); true when it may go ahead.
    static func confirm(_ files: () -> [FileDocument], saveAll: () -> Void, in window: NSWindow? = nil) async -> Bool {
        guard !files().isEmpty else { return true }
        switch await KoreAsk.saveChanges({ files().map(\.name) }, key: "save-files", in: window) {
        case .save:
            saveAll()
            return files().isEmpty
        case .discard:
            return true
        case .cancel:
            return false
        }
    }
}
