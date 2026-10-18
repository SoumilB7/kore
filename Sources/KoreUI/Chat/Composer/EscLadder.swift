import Foundation

/// What Esc in the composer does: the first step that applies, one per press, as both CLIs'
/// Esc stops a turn. Whatever is open over the window or the chat closes first, then a
/// selection in the transcript is let go, and only an Esc with nothing left to close or clear
/// stops the turn. None stops one while a sheet is up.
enum EscStep: Equatable {
    /// A tab's close question, quick open, the floating explorer (`Workspace.hasOverlay`).
    case closeOverlay
    case closeSlashMenu
    /// Usage, Account, the import picker, the usage card, the context card, the agent map.
    case closePopup
    case clearSelection
    case stop
    case nothing

    static func next(overlay: Bool, slashMenu: Bool, popup: Bool, selection: Bool, running: Bool, sheet: Bool) -> EscStep {
        if sheet { return .nothing }
        if overlay { return .closeOverlay }
        if slashMenu { return .closeSlashMenu }
        if popup { return .closePopup }
        if selection { return .clearSelection }
        return running ? .stop : .nothing
    }
}
