import Foundation

/// Debug hooks for file tabs, for snapshots of what keys would otherwise reach (in-process keys
/// don't get to the editor in a snapshot run):
///   KORE_FIND=<query>         open find with that query in the first file tab that shows its text
///   KORE_CONVERT=tabs|spaces  convert that tab's indentation first
@MainActor
enum DevFileHooks {
    private static var done = false

    static func editorShown(_ document: FileDocument) {
        guard !done else { return }
        let env = ProcessInfo.processInfo.environment
        guard env["KORE_FIND"] != nil || env["KORE_CONVERT"] != nil else { return }
        done = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let mode = env["KORE_CONVERT"] { document.convertIndentation(toTabs: mode == "tabs") }
            if let query = env["KORE_FIND"] {
                document.editor.find.isOpen = true
                document.editor.find.query = query
            }
        }
    }
}
