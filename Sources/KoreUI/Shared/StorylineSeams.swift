import Foundation

/// Where a storyline host (phase 12's `kore-storylines`, in the `KoreStorylines` target) reaches
/// into the app. Each is nil in Kore itself, so the app runs as it always has.
@MainActor
package enum StorylineSeams {
    /// Makes every chat's backend in place of its provider's (the scripted CLI), from the
    /// provider's id and what the chat would launch with.
    package static var backend: ((_ provider: String, BackendOptions) -> any ChatBackend)?
    /// Every event a chat applies, in order, once its stores have it.
    package static var events: ((Chat, ChatEvent) -> Void)?
}
