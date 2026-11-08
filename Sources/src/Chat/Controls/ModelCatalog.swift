import Foundation

/// When a CLI's model list is read again: a session's start reads it anyway (free), and a turn's
/// end may ask the running CLI, at most once per `interval` per CLI, one read at a time.
package struct ModelListThrottle {
    package var interval: TimeInterval = 600
    private var last: [String: Date] = [:]
    private var reading: Set<String> = []

    package init(interval: TimeInterval = 600) { self.interval = interval }

    /// A turn ended: whether to ask the CLI now. Asking marks the read begun.
    package mutating func turnEnded(_ cli: String, at now: Date) -> Bool {
        guard !reading.contains(cli) else { return false }
        if let last = last[cli], now.timeIntervalSince(last) < interval { return false }
        reading.insert(cli)
        last[cli] = now
        return true
    }

    /// A list came: a session's start, or the read a turn's end began.
    package mutating func listed(_ cli: String, at now: Date) {
        reading.remove(cli)
        last[cli] = now
    }

    /// The read failed: the next turn's end may try again.
    package mutating func failed(_ cli: String) {
        reading.remove(cli)
        last[cli] = nil
    }
}

/// A chat as the model lists reach it: its CLI, and its picker's rows.
@MainActor
package protocol ModelListHolder: AnyObject {
    var modelCLI: String { get }
    func listModels(_ models: [ModelOption])
}

/// Each CLI's model list, shared by its open chats: a new list reaches every picker as data,
/// never moving a chat off its model.
@MainActor
package final class ModelCatalog {
    package static let shared = ModelCatalog()

    package var throttle = ModelListThrottle()
    /// The clock the throttle reads (a storyline moves it on).
    package var now: () -> Date = Date.init
    package private(set) var lists: [String: [ModelOption]] = [:]
    private var chats: [WeakHolder] = []

    private struct WeakHolder { weak var chat: (any ModelListHolder)? }

    /// Nothing listed or read yet, on the real clock (a storyline's start).
    package func reset() {
        throttle = ModelListThrottle()
        now = Date.init
        lists = [:]
        chats = []
    }

    /// The list a chat's CLI gave as its session started: every chat of that CLI takes it.
    package func started(_ chat: any ModelListHolder, cli: String, models: [ModelOption]) {
        chats.removeAll { $0.chat == nil || $0.chat === chat }
        chats.append(WeakHolder(chat: chat))
        throttle.listed(cli, at: now())
        publish(cli, models, except: chat)
    }

    /// A turn ended in `chat`: its CLI's list is read again when it's due, off the main thread.
    package func turnEnded(_ chat: any ModelListHolder, cli: String, read: @escaping () async -> [ModelOption]?) {
        guard throttle.turnEnded(cli, at: now()) else { return }
        Task { @MainActor in
            guard let models = await read(), !models.isEmpty else { return self.throttle.failed(cli) }
            self.throttle.listed(cli, at: self.now())
            self.publish(cli, models, except: nil)
        }
    }

    private func publish(_ cli: String, _ models: [ModelOption], except: (any ModelListHolder)?) {
        guard !models.isEmpty, lists[cli] != models else { return }
        lists[cli] = models
        chats.removeAll { $0.chat == nil }
        for case let chat? in chats.map(\.chat) where chat !== except && chat.modelCLI == cli {
            chat.listModels(models)
        }
    }

    /// The new list, with the chat's own model kept when the CLI no longer lists it (a 1M
    /// variant, a model set by a settings file): the chat stays on it.
    package nonisolated static func merged(_ fresh: [ModelOption], into old: [ModelOption], current: String?) -> [ModelOption] {
        guard !fresh.isEmpty else { return old }
        guard let current, !fresh.contains(where: { $0.id == current }), let kept = old.first(where: { $0.id == current }) else { return fresh }
        return fresh + [kept]
    }
}
