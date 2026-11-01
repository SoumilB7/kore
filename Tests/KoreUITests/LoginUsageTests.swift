import Foundation
import AppKit
import KoreCore
import Testing

@testable import KoreUI

@Suite("Login usage meters", .serialized) @MainActor
struct LoginUsageTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    @MainActor private final class Flag { var value = false }

    private func key(_ id: String? = nil, email: String = "me@example.com", generation: Int = 0, signedOut: Bool = false) -> LoginUsage.Key {
        LoginUsage.Key("claude", .init(id: id, email: email, active: id == nil, workspace: "Example", signedOut: signedOut), generation: generation)
    }

    private func reading(_ email: String = "me@example.com", used: Double = 43) -> PlanReading {
        PlanReading(account: .init(email: email, organization: "Example", access: .plan), limits: .init(bars: [
            PlanLimit(title: "Session (5hr)", used: used, resetsAt: now.addingTimeInterval(3600), window: 18000),
        ]))
    }

    @Test func theCardReadsOnlyTheActiveLoginAndAHoverReadsAnother() async throws {
        var calls: [String?] = []
        var time = now
        let store = LoginUsage(read: { _, id in
            calls.append(id)
            return reading(id == nil ? "me@example.com" : "new@example.com", used: id == nil ? 43 : 0)
        }, clock: { time })
        let main = key(), unused = key("other", email: "new@example.com")
        // No card shows the list: a hover reads nothing.
        store.hover(unused)
        let card = Task { await store.show([main, unused]) }
        for _ in 0..<100 where calls.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        for _ in 0..<100 where store.state(main) == .loading { try await Task.sleep(for: .milliseconds(2)) }
        #expect(calls == [nil])
        #expect(store.state(main) == .ready(reading(), now))
        #expect(store.state(unused) == .idle)
        store.hover(unused)
        #expect(store.state(unused) == .loading)
        for _ in 0..<100 where calls.count < 2 || store.state(unused) == .loading { try await Task.sleep(for: .milliseconds(2)) }
        #expect(calls == [nil, "other"])
        #expect(store.state(unused) == .ready(reading("new@example.com", used: 0), now))
        // The active login's minute, a hovered login's five.
        time = time.addingTimeInterval(61)
        store.hover(unused)
        await store.refresh([main, unused])
        #expect(calls == [nil, "other", nil])
        time = time.addingTimeInterval(LoginUsage.hoverCache)
        await store.refresh([main, unused])
        #expect(calls == [nil, "other", nil, nil])
        store.hover(unused)
        for _ in 0..<100 where calls.count < 5 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(calls == [nil, "other", nil, nil, "other"])
        card.cancel()
        await card.value
        time = time.addingTimeInterval(LoginUsage.hoverCache + 1)
        store.hover(unused)
        try await Task.sleep(for: .milliseconds(20))
        #expect(calls.count == 5)
    }

    @Test func closingTheCardDropsAHoverReadUnderWay() async throws {
        var calls = 0
        let cancelled = Flag()
        let store = LoginUsage(read: { _, id in
            calls += 1
            if id == nil { return reading() }
            return try await withTaskCancellationHandler {
                try await Task.sleep(for: .seconds(10))
                return reading("other@example.com")
            } onCancel: {
                Task { @MainActor in cancelled.value = true }
            }
        }, clock: { now })
        let main = key(), other = key("other", email: "other@example.com")
        let card = Task { await store.show([main, other]) }
        for _ in 0..<100 where store.state(main) == .loading { try await Task.sleep(for: .milliseconds(2)) }
        store.hover(other)
        for _ in 0..<100 where calls < 2 { try await Task.sleep(for: .milliseconds(2)) }
        card.cancel()
        await card.value
        for _ in 0..<100 where !cancelled.value { try await Task.sleep(for: .milliseconds(2)) }
        #expect(cancelled.value)
        #expect(store.state(other) == .idle)
    }

    @Test func unavailableSignedOutOrMismatchedAccountsNeverBecomeZero() async {
        var calls = 0
        let store = LoginUsage(read: { _, _ in
            calls += 1
            return reading("someone-else@example.com", used: 0)
        })
        let wrong = key(), out = key("out", signedOut: true)
        await store.refresh([wrong, out])
        #expect(store.state(wrong) == .unavailable)
        #expect(store.state(out) == .unavailable)
        #expect(calls == 1)
        var account = reading().account
        account.organization = "Other org"
        #expect(!LoginUsage.matches(account, wrong))
        account.organization = nil
        #expect(!LoginUsage.matches(account, wrong))
        account = reading().account
        account.email = nil
        #expect(!LoginUsage.matches(account, wrong))
    }

    @Test func parallelWindowsShareAReadAndProvidersStaySerial() async {
        var calls = 0, active = 0, peak = 0
        let store = LoginUsage(read: { _, id in
            calls += 1
            active += 1
            peak = max(peak, active)
            try await Task.sleep(for: .milliseconds(20))
            active -= 1
            return reading(id == nil ? "me@example.com" : "other@example.com")
        })
        let main = key(), other = key("other", email: "other@example.com")
        let card = Task { await store.show([main, other]) }
        async let second: Void = store.refresh([main, other])
        for _ in 0..<100 where calls == 0 { try? await Task.sleep(for: .milliseconds(2)) }
        // A hover read waits behind the active login's.
        store.hover(other)
        await second
        for _ in 0..<200 where calls < 2 || active > 0 { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(calls == 2)
        #expect(peak == 1)
        card.cancel()
        await card.value
    }

    @Test func cancellationStopsQueuedReadsAndNewIdentityCannotSeeOldValues() async throws {
        var calls = 0
        let store = LoginUsage(read: { _, _ in
            calls += 1
            try await Task.sleep(for: .seconds(10))
            return reading()
        })
        let old = key(), newer = key(generation: 1), other = key("other")
        let task = Task { await store.refresh([old, other]) }
        for _ in 0..<100 where calls == 0 { try await Task.sleep(for: .milliseconds(2)) }
        task.cancel()
        await task.value
        #expect(calls == 1)
        #expect(store.state(newer) == .loading)
        #expect(store.states[old] == nil)
        #expect(store.states[other] == nil)
    }

    @Test func closingOneWindowKeepsAnotherWindowsSharedRead() async throws {
        var calls = 0
        let store = LoginUsage(read: { _, _ in
            calls += 1
            try await Task.sleep(for: .milliseconds(40))
            return reading()
        })
        let main = key()
        let first = Task { await store.refresh([main]) }
        let second = Task { await store.refresh([main]) }
        try await Task.sleep(for: .milliseconds(10))
        first.cancel()
        await second.value
        await first.value
        #expect(calls == 1)
        guard case .ready = store.state(main) else { Issue.record("The remaining window lost its read"); return }
    }

    @Test func reopeningWhileCancellationFinishesStartsANewRead() async throws {
        var pending: CheckedContinuation<PlanReading, Never>?
        let cancelled = Flag()
        var secondStarted = false, calls = 0
        let store = LoginUsage(read: { _, _ in
            calls += 1
            if calls == 1 {
                return await withTaskCancellationHandler {
                    await withCheckedContinuation { pending = $0 }
                } onCancel: {
                    Task { @MainActor in cancelled.value = true }
                }
            }
            return reading(used: 0)
        }, clock: { now })
        let main = key()
        let first = Task { await store.refresh([main]) }
        for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(2)) }
        first.cancel()
        for _ in 0..<100 where !cancelled.value { try await Task.sleep(for: .milliseconds(2)) }
        let second = Task { secondStarted = true; await store.refresh([main]) }
        for _ in 0..<100 where !secondStarted { try await Task.sleep(for: .milliseconds(2)) }
        pending?.resume(returning: reading(used: 99))
        await first.value
        await second.value
        #expect(calls == 2)
        #expect(store.state(main) == .ready(reading(used: 0), now))
    }

    @Test func matchingIncludesPlanWorkspaceAndClaudesNoOrgFallback() {
        let codex = LoginUsage.Key("codex", .init(id: nil, email: "me@example.com", active: true, workspace: "ChatGPT Pro"), generation: 0)
        #expect(!LoginUsage.matches(.init(plan: "ChatGPT Business", email: "me@example.com", access: .plan), codex))
        #expect(LoginUsage.matches(.init(plan: "ChatGPT Pro", email: "me@example.com", access: .plan), codex))
        let claude = LoginUsage.Key("claude", .init(id: nil, email: "me@example.com", active: true, workspace: "Claude Max"), generation: 0)
        #expect(LoginUsage.matches(.init(plan: "Claude Max", email: "me@example.com", access: .plan), claude))
    }

    @Test func anOldServerCannotPublishAnotherAccountsLiveResponse() async throws {
        var pending: CheckedContinuation<PlanReading, Never>?
        var attributed = false
        let popup = UsageState()
        popup.open(provider: "claude", read: {
            await withCheckedContinuation { pending = $0 }
        }, useReset: { _, _ in .reset }, shares: { _ in attributed = true; return nil },
        cacheScope: "new-\(UUID())", expectedAccount: reading("new@example.com").account)
        for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(2)) }
        pending?.resume(returning: reading("old@example.com"))
        for _ in 0..<100 where popup.status == .loading { try await Task.sleep(for: .milliseconds(2)) }
        #expect(popup.reading == nil && popup.shares == nil)
        #expect(!attributed)
        guard case .unavailable = popup.status else { Issue.record("An identity mismatch must be unavailable"); return }
        popup.close()
    }

    @Test func accountInvalidationDropsAnInFlightResponse() async throws {
        var pending: CheckedContinuation<PlanReading, Never>?
        var returned = false
        let popup = UsageState()
        popup.open(provider: "claude", read: {
            let result = await withCheckedContinuation { pending = $0 }
            returned = true
            return result
        }, useReset: { _, _ in .reset }, cacheScope: "old-\(UUID())", expectedAccount: reading().account)
        for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(2)) }
        popup.accountChanged()
        pending?.resume(returning: reading())
        for _ in 0..<100 where !returned { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!popup.isOpen && !popup.extended)
        #expect(popup.reading == nil && popup.shares == nil)
    }

    @Test func resetRefusesAServerWhoseAccountChangedSinceTheReading() async throws {
        var current = reading(), consumed = 0
        let popup = UsageState()
        popup.open(provider: "claude", read: { current }, useReset: { _, _ in consumed += 1; return .reset },
            cacheScope: "reset-\(UUID())", expectedAccount: current.account)
        for _ in 0..<100 where popup.reading == nil { try await Task.sleep(for: .milliseconds(2)) }
        popup.askReset(nil)
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.01))
        current = reading("other@example.com")
        popup.useReset()
        for _ in 0..<100 where popup.resetSteps[nil] == .using { try await Task.sleep(for: .milliseconds(2)) }
        #expect(consumed == 0)
        guard case .failed = popup.resetSteps[nil] else { Issue.record("A changed server must refuse the reset"); return }
        popup.close()
    }

    @Test func firstStatusCorrectionClearsCachedUsageAndAnonymousLoginDoesNotInheritMain() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("usage-identities-\(UUID())")
        let beforeRoot = CLIProfiles.root.value, beforeMains = CLIProfiles.mains.value
        let beforeCalls = StorylineSeams.accounts
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        CLIProfiles.root.value = folder.appendingPathComponent("accounts")
        CLIProfiles.mains.value = ["codex": folder.appendingPathComponent("main")]
        CLIProfiles.reload()
        AccountStore.shared.reset()
        defer {
            AccountStore.shared.reset()
            StorylineSeams.accounts = beforeCalls
            CLIProfiles.root.value = beforeRoot
            CLIProfiles.mains.value = beforeMains
            CLIProfiles.reload()
            try? FileManager.default.removeItem(at: folder)
        }
        let descriptor = try #require(Registry.provider("claude"))
        var claudeCalls = descriptor.account.calls
        claudeCalls.status = { ["loggedIn": true, "authMethod": "claude.ai", "email": "new@example.com", "orgName": "Example", "subscriptionType": "max"] }
        var codexCalls = try #require(Registry.provider("codex")?.account.calls)
        codexCalls.status = { ["account": ["type": "apiKey"], "requiresOpenaiAuth": false] }
        let calls = ["claude": claudeCalls, "codex": codexCalls]
        StorylineSeams.accounts = { calls[$0] }
        _ = CLIProfiles.note("claude", email: "old@example.com", workspace: "Example")
        let chat = Chat(provider: descriptor, folder: folder)
        chat.usage.open(provider: "claude", read: { reading("old@example.com") }, useReset: { _, _ in .reset })
        for _ in 0..<100 where chat.usage.reading == nil { try await Task.sleep(for: .milliseconds(2)) }
        #expect(chat.usage.reading?.account.email == "old@example.com")
        var pending: CheckedContinuation<PlanReading, Never>?
        var returned = false
        chat.usage.open(provider: "claude", read: {
            let result = await withCheckedContinuation { pending = $0 }
            returned = true
            return result
        }, useReset: { _, _ in .reset })
        for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(2)) }
        let generation = AccountStore.shared.generation("claude")
        await AccountStore.shared.refresh("claude")
        #expect(AccountStore.shared.generation("claude") == generation)
        #expect(!chat.usage.isOpen && chat.usage.reading == nil)
        pending?.resume(returning: reading("old@example.com"))
        for _ in 0..<100 where !returned { try await Task.sleep(for: .milliseconds(2)) }
        #expect(chat.usage.reading == nil)

        // Main's email must not stand in for an anonymous added API-key login.
        _ = CLIProfiles.note("codex", email: "main@example.com", workspace: "ChatGPT Pro")
        let keyLogin = try CLIProfiles.prepare("codex")
        CLIProfiles.adopt("codex", keyLogin, email: nil)
        let popup = UsageState()
        popup.open(provider: "codex", read: { PlanReading(account: .init(access: .perToken("Billed per token")), limits: nil) }, useReset: { _, _ in .reset })
        for _ in 0..<100 where popup.status == .loading { try await Task.sleep(for: .milliseconds(2)) }
        #expect(popup.reading?.account.access == .perToken("Billed per token"))
        #expect(popup.reading?.account.email == nil)
        #expect(CLIProfiles.mainEmail("codex") == "main@example.com")
        popup.close()
    }

    @Test func usagePopupDoesNotReuseAnotherLoginsLimitsOrHatch() async throws {
        let provider = "isolated-\(UUID())"
        let popup = UsageState()
        popup.open(provider: provider, read: { reading() }, useReset: { _, _ in .reset }, shares: { _ in
            KoreShares(at: now, limits: ["Session (5hr)": KoreShare(used: 43, kore: 20)])
        }, cacheScope: "main")
        for _ in 0..<100 where popup.shares == nil { try await Task.sleep(for: .milliseconds(2)) }
        #expect(popup.reading != nil && popup.shares != nil)
        popup.close()
        popup.open(provider: provider, read: { reading("new@example.com", used: 0) }, useReset: { _, _ in .reset }, cacheScope: "new")
        #expect(popup.reading == nil)
        #expect(popup.shares == nil)
        popup.close()
    }

    @Test func attributionCanFinishAfterOpeningTheExtendedView() async throws {
        let popup = UsageState()
        popup.open(provider: "isolated-\(UUID())", read: { reading() }, useReset: { _, _ in .reset }, shares: { _ in
            try? await Task.sleep(for: .milliseconds(30))
            return KoreShares(at: now, limits: ["Session (5hr)": KoreShare(used: 43, kore: 20)])
        }, cacheScope: "main")
        for _ in 0..<100 where popup.reading == nil { try await Task.sleep(for: .milliseconds(2)) }
        popup.openExtended()
        for _ in 0..<100 where popup.shares == nil { try await Task.sleep(for: .milliseconds(2)) }
        #expect(popup.extended)
        #expect(popup.shares?.limits["Session (5hr)"]?.kore == 20)
        popup.accountChanged()
        #expect(!popup.extended && !popup.isOpen)
        #expect(popup.reading == nil && popup.shares == nil)
    }
    @Test func pastedLoginInputCannotCrossCancelledFlows() async throws {
        let previous = StorylineSeams.accounts
        let previousOpened = StorylineSeams.opened
        StorylineSeams.opened = { _ in }
        let store = AccountStore()
        var pending: CheckedContinuation<JSONValue?, any Error>?
        var submissions = 0
        StorylineSeams.accounts = { _ in AccountCalls(
            status: { ["account": nil] },
            signIn: { @MainActor _, _ in
                SignInHandle(url: URL(string: "https://example.com/sign-in"),
                    wait: { @MainActor in try await withCheckedThrowingContinuation { pending = $0 } },
                    cancel: { @MainActor in pending?.resume(throwing: CancellationError()); pending = nil },
                    submit: { @MainActor _ in submissions += 1 })
            }, useKey: { _ in nil }, signOut: {}) }
        defer {
            store.cancel("codex")
            StorylineSeams.accounts = previous
            StorylineSeams.opened = previousOpened
        }
        let folder = FileManager.default.temporaryDirectory
        store.signIn("codex", in: folder)
        for _ in 0..<100 where !store.acceptsSignInInput("codex") { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.acceptsSignInInput("codex"))
        let before = store.signInSerial("codex")
        store.cancel("codex")
        for _ in 0..<100 where pending != nil { try await Task.sleep(for: .milliseconds(5)) }
        store.signIn("codex", in: folder)
        for _ in 0..<100 where !store.acceptsSignInInput("codex") { try await Task.sleep(for: .milliseconds(5)) }
        do {
            try await store.submitSignIn("old-input", provider: "codex", serial: before)
            Issue.record("A cancelled flow submitted into the new login")
        } catch { }
        #expect(submissions == 0)
        try await store.submitSignIn("new-input", provider: "codex", serial: store.signInSerial("codex"))
        #expect(submissions == 1)
        store.cancel("codex")
        for _ in 0..<100 where pending != nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func refreshAndCancellationNeverBlankConfirmedMeters() async throws {
        var calls = 0, time = now
        let store = LoginUsage(read: { _, _ in
            calls += 1
            if calls > 1 { try await Task.sleep(for: .seconds(10)) }
            return reading()
        }, clock: { time })
        let main = key()
        await store.refresh([main])
        let confirmed = store.state(main)
        time = time.addingTimeInterval(61)
        let refresh = Task { await store.refresh([main]) }
        for _ in 0..<100 where calls < 2 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(calls == 2 && store.state(main) == confirmed)
        refresh.cancel()
        await refresh.value
        #expect(store.state(main) == confirmed)
    }

    @Test func unchangedIdentitySurvivesGenerationAndNetworkFailure() async {
        enum Offline: Error { case failed }
        var calls = 0
        let store = LoginUsage(read: { _, _ in
            calls += 1
            if calls > 1 { throw Offline.failed }
            return reading()
        }, clock: { now })
        let original = key(), same = key(generation: 1), different = key(email: "other@example.com", generation: 2)
        await store.refresh([original])
        let confirmed = store.state(original)
        #expect(store.state(same) == confirmed)
        await store.refresh([same])
        #expect(calls == 2 && store.state(same) == confirmed)
        #expect(store.state(different) == .loading)
        await store.refresh([different])
        #expect(store.state(different) == .unavailable)
        #expect(store.states[original] == nil && store.states[same] == nil)
    }

    @Test func successfulMismatchClearsTheConfirmedReadingAcrossGenerations() async throws {
        var pending: CheckedContinuation<PlanReading, Never>?
        var calls = 0
        let store = LoginUsage(read: { _, _ in
            calls += 1
            if calls == 1 { return reading() }
            return await withCheckedContinuation { pending = $0 }
        }, clock: { now })
        let original = key(), refreshed = key(generation: 1), later = key(generation: 2)
        await store.refresh([original])
        let verified = store.state(original)
        let refresh = Task { await store.refresh([refreshed]) }
        for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(2)) }
        #expect(store.state(refreshed) == verified)
        let reply = try #require(pending)
        reply.resume(returning: reading("someone-else@example.com"))
        await refresh.value
        #expect(store.state(refreshed) == .unavailable)
        #expect(store.state(later) == .loading)
        #expect(store.states[original] == nil)
    }

    @Test func confirmedValuesNeverCrossLoginProviderOrWorkspace() async {
        let store = LoginUsage(read: { _, _ in reading() }, clock: { now })
        let main = key()
        await store.refresh([main])
        let otherLogin = key("other")
        let otherProvider = LoginUsage.Key("codex", .init(id: nil, email: "me@example.com", active: true, workspace: "Example"), generation: 1)
        let otherWorkspace = LoginUsage.Key("claude", .init(id: nil, email: "me@example.com", active: true, workspace: "Other org"), generation: 1)
        #expect(store.state(otherLogin) == .idle)
        #expect(store.state(otherProvider) == .loading)
        #expect(store.state(otherWorkspace) == .loading)
        #expect(store.state(key(signedOut: true)) == .loading)
        #expect(store.state(key(generation: 1)) == .ready(reading(), now))
    }

    @Test func replacedIdentityCannotRepublishAfterItsCancelledReadReturns() async throws {
        var pending: CheckedContinuation<PlanReading, Never>?
        var calls: [String?] = []
        let cancelled = Flag()
        let store = LoginUsage(read: { _, login in
            calls.append(login)
            if pending == nil {
                return await withTaskCancellationHandler {
                    await withCheckedContinuation { pending = $0 }
                } onCancel: {
                    Task { @MainActor in cancelled.value = true }
                }
            }
            return reading("new@example.com")
        }, clock: { now })
        let old = key(), obsolete = key("removed"), newer = key(email: "new@example.com", generation: 1)
        let oldRefresh = Task { await store.refresh([old, obsolete]) }
        for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(2)) }
        let reply = try #require(pending)
        let newRefresh = Task { await store.refresh([newer]) }
        for _ in 0..<100 where !cancelled.value { try await Task.sleep(for: .milliseconds(2)) }
        #expect(cancelled.value)
        reply.resume(returning: reading())
        await oldRefresh.value
        await newRefresh.value
        #expect(store.states[old] == nil)
        #expect(store.states[obsolete] == nil)
        #expect(calls == [nil, nil])
        #expect(store.state(newer) == .ready(reading("new@example.com"), now))
    }

}
