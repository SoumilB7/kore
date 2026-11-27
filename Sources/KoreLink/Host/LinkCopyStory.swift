import Foundation
import KoreUI
import LinkProtocol

/// A phone's copy as a storyline asks for it: the phone's own checks (`LinkAsk`), then the Mac's
/// action, as `LinkPeer` runs a phone's command.
@MainActor
package enum LinkCopyStory {
    /// The phone the storyline is.
    private static let phone = UUID()

    package static func window(_ workspace: Workspace) -> String { LinkSnapshot.windowID(workspace) }

    /// What the phone hears: nil for done, else the line.
    package static func ask(_ ask: CopyAsk) async -> String? {
        var args = ControlArgs()
        args.copy = ask
        if case .deny(_, let line) = LinkAsk.check(.chatCopyVia, args, nil, arsenal: nil) { return line }
        let outcome = await LinkControlActions.apply(.chatCopyVia, args, control: .full, phone: phone)
        return outcome.ok ? nil : outcome.message ?? "refused"
    }
}
