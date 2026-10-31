import Foundation
import KoreCore

/// Where a storyline host (phase 12's `kore-storylines`, in the `KoreStorylines` target) reaches
/// into the app. Each is nil in Kore itself, so the app runs as it always has.
@MainActor
package enum StorylineSeams {
    /// Makes every chat's backend in place of its provider's (the scripted CLI), from the
    /// provider's id and what the chat would launch with.
    package static var backend: ((_ provider: String, BackendOptions) -> any ChatBackend)?
    /// Each CLI's login calls (status, sign-in, sign-out) in place of the CLI's own, by
    /// provider id; nil for one left as it is.
    package static var accounts: ((_ provider: String) -> AccountCalls?)?
    /// Account-list plan reads for a login (nil: main), without starting real CLIs.
    package static var loginUsage: ((_ provider: String, _ login: String?) async throws -> PlanReading)?
    /// A sign-in page Kore would have opened in the browser (under a host nothing opens).
    package static var opened: ((URL) -> Void)?
    /// The file an open panel would have given (a Vertex key file); nil, none picked.
    package static var chooseFile: (() -> URL?)?
    /// The scripted CLI's chats in a folder's history, by provider id: added to the CLI's own
    /// list, or in place of it (`own` false: a real Codex would read the owner's threads).
    package static var sessions: ((_ provider: String, _ folder: URL) -> (own: Bool, extra: [SessionSummary]))?
}
