import AppKit
import Foundation
import KoreCore
import Testing
@testable import HostClient
@testable import src

@testable import KoreLink
@testable import KoreUI

/// Arsenal across Kore's restarts: the switch and each chat's tier are kept in the defaults, and a
/// new process (its own reader of the same domain, nothing held in memory) reads them back at
/// launch, so a chat back in a window is on again at the tier it had, with the socket. The switch
/// turned off by hand forgets every chat's. Synchronous: no other suite runs in between.
@MainActor
@Suite("arsenal across a relaunch", .serialized)
struct ArsenalRelaunchTests {
    static let domain = "kore-arsenal-relaunch-tests"
    static let session = SessionSummary(id: "s-relaunch", agent: .claude, title: "Kept", updated: .now)

    static func chat() throws -> Chat {
        Chat(provider: try #require(Registry.provider("claude")), folder: URL(fileURLWithPath: "/tmp/kore-arsenal-relaunch-tests"), resume: session)
    }

    /// What Kore holds in memory, gone as a quit takes it; what's in the defaults stays.
    static func quit() {
        AgentGrants.stopAll()
        Arsenal.shared.adopt(allowed: false)
    }

    /// The switch and the tiers in a domain of their own, a socket folder of its own; `body`, then
    /// the hooks and readers as they were.
    static func rig(_ body: (UserDefaults) throws -> Void) throws {
        let before = (AgentGrants.defaults, ArsenalMemory.defaults, AgentChannel.directory, HostConnection.toolCalls)
        UserDefaults.standard.removePersistentDomain(forName: domain)
        let defaults = try #require(UserDefaults(suiteName: domain))
        AgentGrants.defaults = defaults
        ArsenalMemory.defaults = defaults
        AgentChannel.directory = URL(fileURLWithPath: "/tmp/kar-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer {
            quit()
            AgentTaps.setAllowed = nil
            AgentTaps.setTier = nil
            AgentTaps.stopAll = nil
            (AgentGrants.defaults, ArsenalMemory.defaults, AgentChannel.directory, HostConnection.toolCalls) = before
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        quit()
        try body(defaults)
    }

    @Test func theSwitchAndAChatsTierComeBackInANewProcess() throws {
        try Self.rig { _ in
            AgentGrants.install()
            #expect(!Arsenal.shared.allowed)

            // The first run: the user turns a chat on (the switch with it) and picks Act unlimited.
            let chat = try Self.chat()
            Arsenal.shared.flip(chat)
            Arsenal.shared.choose(.drive, chat)
            #expect(Arsenal.shared.allowed && chat.arsenal == .drive && AgentChannel.current != nil)
            Arsenal.shared.closed(chat)
            Self.quit()
            #expect(AgentChannel.current == nil && !Arsenal.shared.allowed)

            // A new process: its own reader of the same domain has the switch on and the tier kept.
            let second = try #require(UserDefaults(suiteName: Self.domain))
            #expect(second.bool(forKey: AgentGrants.switchKey))
            AgentGrants.defaults = second
            ArsenalMemory.defaults = second
            AgentGrants.install()
            #expect(Arsenal.shared.allowed)
            // The chat back in its window (what its register's task does).
            let back = try Self.chat()
            Arsenal.shared.restore(back)
            #expect(back.arsenal == .drive && AgentGrants.tier(chat: back.id.uuidString) == .drive && AgentChannel.current != nil)

            // The switch off by hand forgets it, for the next process too.
            Arsenal.shared.setAllowed(false)
            let third = try #require(UserDefaults(suiteName: Self.domain))
            #expect(!third.bool(forKey: AgentGrants.switchKey) && third.array(forKey: ArsenalMemory.defaultsKey) == nil)
            #expect(back.arsenal == nil && AgentChannel.current == nil)
        }
    }

    /// A chat already in a window when the switch is read (not Kore's launch order, but no
    /// matter): its kept tier comes back then.
    @Test func aChatOpenBeforeTheSwitchIsReadComesBackToo() throws {
        try Self.rig { defaults in
            defaults.set(true, forKey: AgentGrants.switchKey)
            ArsenalMemory.keep(.own, under: "claude:" + Self.session.id)
            let chat = try Self.chat()
            Arsenal.shared.restore(chat)
            #expect(chat.arsenal == nil)
            let workspace = Workspace(folder: chat.folder, restore: false)
            workspace.tabs[0].chat = chat
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            workspace.window = window
            defer { workspace.window = nil }
            AgentGrants.install()
            #expect(chat.arsenal == .own && AgentGrants.tier(chat: chat.id.uuidString) == .own && AgentChannel.current != nil)
        }
    }
}
