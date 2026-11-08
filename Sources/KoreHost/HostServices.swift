import Foundation
import KoreCore
import src

/// What the box supplies to its chats: the CLI's own backend, its transcript without rows, and
/// nothing of the Mac's (no Stay awake, no taps but its own, no view state). Each event a chat
/// takes is handed to `onEvent`, which sends the chat's new state on.
@MainActor
package final class HostServices: ChatServices {
    package var onEvent: ((Chat, ChatEvent) -> Void)?
    /// A chat's transcript was built again in a new store: the box follows that one.
    package var onTranscript: ((Chat) -> Void)?
    /// A CLI's model list came: its session's start, or a turn's end read it again (`ModelCatalog`).
    package var onModels: ((String, [ModelOption]) -> Void)?
    /// Makes the backend; tests set a stand-in.
    package var backend: (ProviderDescriptor, BackendOptions) -> any ChatBackend = { $0.makeBackend($1) }

    /// The box's paragraph for every chat (`HostDaemon` writes it): where it runs, and when
    /// Kore's tools are there.
    package var instructions: URL?
    /// No `kore` on a box, and no Arsenal notes of its own: the Mac's come with its messages.
    package var agentTools: Bool { false }
    /// kore-host's `kore_app` server for a chat whose Arsenal is on (`HostAgent`).
    package var server: ((Chat) -> KoreReach.Server?)?
    package func agentServer(_ chat: Chat) -> KoreReach.Server? { server?(chat) }

    package init() {}

    /// What kind of machine the CLIs are told they're on.
    nonisolated package static var machine: String {
        #if os(macOS)
        "a Mac"
        #else
        "a Linux machine"
        #endif
    }

    nonisolated package static func instructions(host: String, machine: String = machine) -> String {
        "This chat runs on \(host), \(machine), through kore-host. The user sees it as a tab in Kore on their Mac. "
            + "Kore's tools are available when the user turns Arsenal on for this chat."
    }

    /// Told with the `kore_app` server, after the box's paragraph.
    package static let toolInstructions = """
        Kore gives you `kore_app` tools to act on Kore on the user's Mac: kore_new_chat opens a new tab with a claude \
        or codex chat (on this machine, or with place mac on the Mac), kore_send sends a message to another chat, \
        kore_list_chats and kore_read_chat read chats, kore_set_model changes this chat's model, and more. \
        Ordinary coding needs none of them. Use them when the user asks for something in Kore, such as another tab \
        or agent. They work only at a tier that covers the request (Read, Act limited, Act unlimited); otherwise a \
        tool answers how the user changes it: tell the user that. Never run the claude or codex CLI yourself in place \
        of a Kore chat.
        """

    package func makeBackend(_ provider: ProviderDescriptor, _ options: BackendOptions) -> any ChatBackend { backend(provider, options) }
    package func planWindows(_ cli: String, _ snapshot: PlanSnapshot?) {}
    package func makeTranscript() -> any ChatTranscript { HostTranscript() }
    package func makeViewState() -> AnyObject { HostViewState.shared }
    package func register(_ chat: Chat) {}
    package func closed(_ chat: Chat) {}
    package func refreshAccount(_ cli: String) {}
    package func modelsListed(_ cli: String, _ models: [ModelOption]) { onModels?(cli, models) }
    package func arsenalFollowMode(_ chat: Chat) {}
    package func tap(_ chat: Chat, _ event: ChatEvent) { onEvent?(chat, event) }
    package func transcriptReplaced(_ chat: Chat) { onTranscript?(chat) }
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
