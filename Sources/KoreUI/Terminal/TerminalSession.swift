import Foundation
import SwiftTerm

/// A terminal tab's shell, wherever it runs: on this Mac (`TerminalShell`) or on a box
/// (`BoxTerminalShell`). The panel, its names and cues treat both the same.
@MainActor
protocol TerminalSession: AnyObject {
    var id: UUID { get }
    /// The shell's own name, or the title it set.
    var title: String { get }
    var ended: Bool { get }
    /// Why it couldn't start, or ended early; shown under it.
    var failure: String? { get }
    var terminalView: TerminalView { get }
    /// Running something now (sampled once, for a close or quit).
    var hasWork: Bool { get }
    /// Starts once its view is laid out.
    func start()
    func close(immediately: Bool)
}
