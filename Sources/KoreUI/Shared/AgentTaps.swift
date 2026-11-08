/// Where Kore meets its agent channel (the KoreLink module's `AgentChannel`,
/// `z-docs/agent-protocol.md`). While no caller follows a transcript, `on` is false and the hook
/// costs one branch.
@MainActor
package enum AgentTaps {
    /// Some caller follows a chat: every event a chat applies is handed over.
    package static var on = false
    package static var event: ((Chat, ChatEvent) -> Void)?
    /// A chat closed, while the channel is open (nil otherwise).
    package static var closed: ((Chat) -> Void)?
    /// What `Arsenal` asks of the channel; the app sets them at launch (`AgentGrants.install`).
    package static var setAllowed: ((Bool) -> Void)?
    package static var setTier: ((_ chat: String, ArsenalTier?) -> Void)?
    package static var stopAll: (() -> Void)?
}

extension Chat {
    /// Its context as the CLI last reported it: tokens in it, and the window when known.
    package var agentContext: (used: Int, window: Int?)? { context.usage.map { ($0.used, $0.window) } }
}
