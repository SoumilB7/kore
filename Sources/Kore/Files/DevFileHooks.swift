import Foundation

/// Debug hooks for file tabs, for snapshots of what keys would otherwise reach (in-process keys
/// don't get to the editor in a snapshot run):
///   KORE_FIND=<query>         open find with that query in the first file tab that shows its text
///   KORE_CONVERT=tabs|spaces  convert that tab's indentation first
///   KORE_FOLD=<line>[,<line>...]  fold the regions starting on those lines (1-based)
///   KORE_TREE_MOVE=<path>|<folder>[|copy]  drop that item on that folder in the explorer, 2s in
///   KORE_TREE_COLLISION=replace|keep|cancel  the answer when its name is taken (no alert)
///   KORE_TREE_UNDO=1          undo it 2s later, through the window's undo manager
@MainActor
enum DevFileHooks {
    private static var done = false

    static func editorShown(_ document: FileDocument) {
        guard !done else { return }
        let env = ProcessInfo.processInfo.environment
        guard env["KORE_FIND"] != nil || env["KORE_CONVERT"] != nil || env["KORE_FOLD"] != nil else { return }
        done = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let mode = env["KORE_CONVERT"] { document.convertIndentation(toTabs: mode == "tabs") }
            for line in (env["KORE_FOLD"] ?? "").split(separator: ",").compactMap({ Int($0) }) {
                document.editor.fold(line: line - 1)
            }
            if let query = env["KORE_FIND"] {
                document.editor.find.isOpen = true
                document.editor.find.query = query
            }
        }
    }

    private static var moved = false

    static func explorerShown(store: FilesStore, workspace: Workspace, undo: UndoManager?) {
        let env = ProcessInfo.processInfo.environment
        guard !moved, let spec = env["KORE_TREE_MOVE"]?.split(separator: "|").map(String.init), spec.count >= 2 else { return }
        moved = true
        let answer: FilesStore.Collision? = switch env["KORE_TREE_COLLISION"] {
        case "replace": .replace
        case "keep": .keepBoth
        case "cancel": .cancel
        default: nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            TreeActions.drop(
                [spec[0]], into: spec[1], copy: spec.count > 2 && spec[2] == "copy", store: store, workspace: workspace,
                undo: undo, answer: answer)
            guard env["KORE_TREE_UNDO"] == "1" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { undo?.undo() }
        }
    }
}
