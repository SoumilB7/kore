import Foundation
import KoreCore

/// Where a storyline host (phase 12's `kore-storylines`, in the `KoreStorylines` target) reaches
/// into the app. Each is nil in Kore itself, so the app runs as it always has.
@MainActor
package enum StorylineSeams {
    /// Makes every chat's backend in place of its provider's (the scripted CLI), from the
    /// provider's id and what the chat would launch with.
    package static var backend: ((_ provider: String, BackendOptions) -> any ChatBackend)?
    /// Every event a chat applies, in order, once its stores have it.
    package static var events: ((Chat, ChatEvent) -> Void)?
    /// Each CLI's login calls (status, sign-in, sign-out) in place of the CLI's own, by
    /// provider id; nil for one left as it is.
    package static var accounts: ((_ provider: String) -> AccountCalls?)?
    /// Account-list plan reads for a login (nil: main), without starting real CLIs.
    package static var loginUsage: ((_ provider: String, _ login: String?) async throws -> PlanReading)?
    /// A sign-in page Kore would have opened in the browser (under a host nothing opens).
    package static var opened: ((URL) -> Void)?
    /// The file an open panel would have given (a Vertex key file); nil, none picked.
    package static var chooseFile: (() -> URL?)?
}
