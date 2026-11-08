import Foundation
import KoreCore
import src

/// What the Mac app supplies to every chat: the backend (a storyline's or the dev feed's
/// stand-in while one is set, else the CLI's), the transcript store and view state, the
/// account, Stay awake, the network watch, the interface log, Arsenal and the taps.
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

    func makeTranscript() -> any ChatTranscript { TranscriptStore() }

    func makeViewState() -> AnyObject { ChatViewState() }

    func register(_ chat: Chat) {
        AccountStore.shared.register(chat)
        StayAwake.register(chat)
        chat.ownPopups()
    }

    func closed(_ chat: Chat) {
        Arsenal.shared.closed(chat)
        AgentTaps.closed?(chat)
    }

    func refreshAccount(_ cli: String) {
        Task { await AccountStore.shared.refresh(cli) }
    }

    func modelsListed(_ cli: String, _ models: [ModelOption]) { ArsenalModels.record(cli, models) }

    func arsenalFollowMode(_ chat: Chat) {
        if Arsenal.unavailable(chat) != nil { Arsenal.shared.turnOff(chat) }
    }

    func tap(_ chat: Chat, _ event: ChatEvent) {
        StorylineSeams.events?(chat, event)
        if LinkTaps.on { LinkTaps.event?(chat, event) }
        if AgentTaps.on { AgentTaps.event?(chat, event) }
    }

    func log(_ name: String, _ fields: KeyValuePairs<String, String?>) { UILog.event(name, fields) }

    var timeReplay: Bool { DevSnapshot.timeReplay }

    func logReplay(_ took: Duration) { DevSnapshot.logReplay(took) }

    var isOnline: Bool { NetworkWatch.shared.isOnline }

    var networkChanged: Notification.Name { NetworkWatch.changed }

    func online() async { await NetworkWatch.shared.online() }

    var awakeClock: (any AwakeClock)? { StayAwake.current?.clock }

    var stayingAwake: Bool { StayAwake.current?.isOn == true }

    func stayAwakeForReset() -> Bool {
        guard let awake = StayAwake.current, !awake.isOn else { return false }
        awake.choose(.whileAgentsWork)
        return true
    }

    func releaseAwake(besides chat: Chat) {
        guard let awake = StayAwake.current, awake.isOn, !awake.othersContinue(besides: chat) else { return }
        awake.turnOff()
    }

    func sleptThrough(since date: Date) -> Bool { StayAwake.current?.sleptThrough(since: date) == true }

    func attachments(_ urls: [URL]) -> [Attachment] { urls.map(Attachment.init(url:)) }

    func reattach(_ sent: [Attachment]) -> [Attachment] { Chat.reattach(sent) }
}
