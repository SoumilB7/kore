import Foundation

/// The folder window's menu commands, as actions on its workspace: the menu runs them for the
/// focused window, and storylines run the same ones for theirs (a window that isn't focused
/// has no focused value, so the menu can't reach it).
package enum WorkspaceCommand: String, CaseIterable, Sendable {
    case newTab, newBoard, closeTab, nextTab, previousTab, moveTabRight, moveTabLeft, save, saveAll, goToFile, goToLine, toggleExplorer, search
    case reload, stop, reopenClosedTab
}

extension Workspace {
    /// Whether the command does anything here (the menu item's enabled state).
    package func can(_ command: WorkspaceCommand) -> Bool {
        switch command {
        case .newTab, .newBoard, .closeTab, .nextTab, .previousTab, .moveTabRight, .moveTabLeft, .goToFile, .toggleExplorer, .search, .reload: true
        case .reopenClosedTab: canReopenClosedTab
        case .stop: activeTab.chat?.isBusy == true
        case .save, .goToLine: activeFile?.isText == true
        case .saveAll: hasUnsavedFiles
        }
    }

    package func perform(_ command: WorkspaceCommand) {
        guard can(command) else { return }
        switch command {
        case .reopenClosedTab: reopenClosedTab()
        case .newTab: newTab()
        case .newBoard: newBoard()
        case .closeTab: requestClose(activeTab, window: isLast(activeTab))
        case .nextTab: selectAdjacent(1)
        case .previousTab: selectAdjacent(-1)
        case .moveTabRight: moveActive(by: 1)
        case .moveTabLeft: moveActive(by: -1)
        case .save: activeFile?.save()
        case .saveAll: saveAll()
        case .goToFile: quickOpen = .files
        case .goToLine: quickOpen = .line
        case .toggleExplorer:
            if explorerOpen, sidebar == .explorer {
                explorerOpen = false
            } else {
                explorerOpen = true
                sidebar = .explorer
            }
        case .search: showSearch()
        case .reload: reload()
        case .stop: activeTab.chat?.stop()
        }
    }

    /// The explorer is showing its file tree (the Hide Explorer state).
    var showsExplorer: Bool { explorerOpen && sidebar == .explorer }
}
