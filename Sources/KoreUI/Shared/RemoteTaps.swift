import Foundation

/// Every event a chat applies, once its stores have it, handed to whoever listens: the phone
/// remote's host, and a storyline host. With no listener, `Chat.dispatch` pays one check.
@MainActor
package enum RemoteTaps {
    package typealias Listener = @MainActor (Chat, ChatEvent) -> Void

    private static var listeners: [UUID: Listener] = [:]
    /// Someone listens.
    package private(set) static var active = false

    @discardableResult
    package static func add(_ listener: @escaping Listener) -> UUID {
        let id = UUID()
        listeners[id] = listener
        active = true
        return id
    }

    package static func remove(_ id: UUID) {
        listeners[id] = nil
        active = !listeners.isEmpty
    }

    static func post(_ chat: Chat, _ event: ChatEvent) {
        for listener in listeners.values { listener(chat, event) }
    }
}
