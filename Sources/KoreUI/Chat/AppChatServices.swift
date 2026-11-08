import Foundation
import KoreCore
import src

/// What the Mac app supplies to every chat's engine: the backend (a storyline's or the dev
/// feed's stand-in while one is set, else the CLI's), and the usage mark, fed by each turn's
/// plan windows.
@MainActor
final class AppChatServices: ChatServices {
    static let shared = AppChatServices()

    func makeBackend(_ provider: ProviderDescriptor, _ options: BackendOptions) -> any ChatBackend {
        if let seam = StorylineSeams.backend { return seam(provider.id, options) }
        return FeedBackend.enabled ? FeedBackend(options) : provider.makeBackend(options)
    }

    func planWindows(_ cli: String, _ snapshot: PlanSnapshot?) {
        UsageCues.shared.take(cli, snapshot: snapshot)
    }
}
