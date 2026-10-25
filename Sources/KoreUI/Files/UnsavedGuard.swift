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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let workspace {
            guard TerminalPanel.confirm(working: workspace.terminals.workingCount),
                  Self.confirm(workspace.unsavedFiles, saveAll: workspace.saveAll) else { return false }
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

    /// Save all, cancel, or discard; true when it may go ahead.
    static func confirm(_ files: [FileDocument], saveAll: () -> Void) -> Bool {
        guard !files.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = files.count == 1
            ? "Do you want to save the changes you made to \(files[0].name)?"
            : "Do you want to save the changes you made to \(files.count) files?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: files.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveAll()
            return files.allSatisfy { !$0.isDirty }
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }
}
