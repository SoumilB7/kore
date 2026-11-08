import Foundation
import KoreCore
import src

/// What the box supplies to its chats: the CLI's own backend, its transcript without rows, and
/// nothing of the Mac's (no Stay awake, no taps but its own, no view state). Each event a chat
/// takes is handed to `onEvent`, which sends the chat's new state on.
@MainActor
package final class HostServices: ChatServices {
    package var onEvent: ((Chat, ChatEvent) -> Void)?
    /// Makes the backend; tests set a stand-in.
    package var backend: (ProviderDescriptor, BackendOptions) -> any ChatBackend = { $0.makeBackend($1) }

    package init() {}

    package func makeBackend(_ provider: ProviderDescriptor, _ options: BackendOptions) -> any ChatBackend { backend(provider, options) }
    package func planWindows(_ cli: String, _ snapshot: PlanSnapshot?) {}
    package func makeTranscript() -> any ChatTranscript { HostTranscript() }
    package func makeViewState() -> AnyObject { HostViewState.shared }
    package func register(_ chat: Chat) {}
    package func closed(_ chat: Chat) {}
    package func refreshAccount(_ cli: String) {}
    package func modelsListed(_ cli: String, _ models: [ModelOption]) {}
    package func arsenalFollowMode(_ chat: Chat) {}
    package func tap(_ chat: Chat, _ event: ChatEvent) { onEvent?(chat, event) }
    package func log(_ name: String, _ fields: KeyValuePairs<String, String?>) {}
    package var timeReplay: Bool { false }
    package func logReplay(_ took: Duration) {}
    /// The box doesn't watch the network: a send that finds it gone fails, and says so.
    package var isOnline: Bool { true }
    package var networkChanged: Notification.Name { Notification.Name("KoreHostNetworkChanged") }
    package func online() async {}
    package var awakeClock: (any AwakeClock)? { nil }
    package var stayingAwake: Bool { false }
    package func stayAwakeForReset() -> Bool { false }
    package func releaseAwake(besides chat: Chat) {}
    package func sleptThrough(since date: Date) -> Bool { false }
    package func attachments(_ urls: [URL]) -> [Attachment] {
        urls.map { Attachment(name: $0.lastPathComponent, kind: Attachments.kind(of: $0), url: $0, imageData: nil, look: nil) }
    }
    package func reattach(_ sent: [Attachment]) -> [Attachment] {
        sent.filter { $0.url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    }
}

/// The box keeps no view state: every chat shares this empty one.
final class HostViewState: Sendable {
    static let shared = HostViewState()
}
