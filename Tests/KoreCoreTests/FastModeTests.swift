import Foundation
import Testing

@testable import KoreCore

/// Fast mode on the wire: Claude's `apply_flag_settings` and `fast_mode_state`, Codex's service
/// tier. The messages are shaped as the CLIs send them, trimmed to the fields read.
@Suite("Fast mode")
struct FastModeTests {
    private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    @Test func claudeSwitchesItThroughFlagSettings() {
        #expect(JSONValue.object(ClaudeSession.fastModeFields(true)).compact == #"{"settings":{"fastMode":true}}"#)
        #expect(JSONValue.object(ClaudeSession.fastModeFields(false)).compact == #"{"settings":{"fastMode":false}}"#)
    }

    @Test func aLaunchNeverEnablesFastModeToDiscoverAvailability() {
        let folder = URL(fileURLWithPath: "/w")
        for on in [false, true] {
            let args = ClaudeSession.Options(cwd: folder, fastMode: on).arguments
            let at = args.firstIndex(of: "--settings")
            #expect(at.map { args[$0 + 1] } == (on ? #"{"fastMode":true}"# : #"{"fastMode":false}"#))
        }
        #expect(!ClaudeSession.Options(cwd: folder).arguments.contains("--settings"))
    }

    @Test func ordinaryStartupDoesNotNeedASwitchAndAnExplicitRefusalSurfaces() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("fast-mode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let fake = work.appendingPathComponent("fake-cli")
        // An older or restricted CLI can initialize but rejects apply_flag_settings.
        let script = """
            #!/usr/bin/python3
            import json, sys
            for line in sys.stdin:
                message = json.loads(line)
                response = {"request_id": message["request_id"]}
                if message["request"]["subtype"] == "initialize":
                    response.update(subtype="success", response={"fast_mode_state":"off", "fast_mode_disabled_reason":"sdk_opt_in_required"})
                else:
                    response.update(subtype="error", error="fast mode blocked for this account")
                print(json.dumps({"type":"control_response", "response":response}), flush=True)
            """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let session = try await ClaudeSession.start(.init(cwd: work, fastMode: false, executable: fake))
        #expect(await session.fastMode == ClaudeFastMode(state: .off, blocked: "sdk_opt_in_required"))
        do {
            try await session.setFastMode(true)
            Issue.record("the CLI's refusal must reach the caller")
        } catch ClaudeSession.Failure.controlError(let reason) {
            #expect(reason == "fast mode blocked for this account")
        }
        await session.close()
    }

    @Test func initializeSaysWhetherTheAccountCanHaveIt() throws {
        // Not opted in: the CLI names only that.
        let unasked = try #require(ClaudeFastMode(json(#"{"fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required"}"#)))
        #expect(unasked.state == .off && unasked.offered == nil)
        // Opted in: what really stops it, or nothing.
        let blocked = try #require(ClaudeFastMode(json(#"{"fast_mode_state":"off","fast_mode_disabled_reason":"extra_usage_disabled"}"#)))
        #expect(blocked.offered == false)
        let open = try #require(ClaudeFastMode(json(#"{"fast_mode_state":"on"}"#)))
        #expect(open.state == .on && open.offered == true)
        // An older CLI says nothing of it.
        #expect(ClaudeFastMode(try json(#"{"models":[]}"#)) == nil)
        #expect(ClaudeFastMode(try json(#"{"fast_mode_state":"warp"}"#)) == nil)
    }

    @Test func eachResultSaysItAgain() throws {
        let result = try json(#"{"type":"result","subtype":"success","is_error":false,"fast_mode_state":"cooldown"}"#)
        guard case .turnCompleted(let turn) = ClaudeEvent(message: result) else {
            Issue.record("not a result")
            return
        }
        #expect(turn.fastMode == ClaudeFastMode(state: .cooldown))
        let older = try json(#"{"type":"result","subtype":"success","is_error":false}"#)
        guard case .turnCompleted(let plain) = ClaudeEvent(message: older) else {
            Issue.record("not a result")
            return
        }
        #expect(plain.fastMode == nil)
    }

    @Test func codexSetsTheThreadsTierAndClearsItWithNull() {
        #expect(CodexSession.serviceTierParams("t1", "priority").compact == #"{"serviceTier":"priority","threadId":"t1"}"#)
        #expect(CodexSession.serviceTierParams("t1", nil).compact == #"{"serviceTier":null,"threadId":"t1"}"#)
    }

    @Test func codexRefusalKeepsTheConfirmedTierAndNullClearsIt() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("fast-tier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let fake = work.appendingPathComponent("fake-cli")
        let script = """
            #!/usr/bin/python3
            import json, sys
            refused = False
            for line in sys.stdin:
                message = json.loads(line)
                if "id" not in message: continue
                response = {"id": message["id"], "result": {}}
                if message["method"] == "thread/start":
                    response["result"] = {"thread":{"id":"t1"}, "model":"gpt-6-luna", "serviceTier":None}
                elif message["method"] == "thread/settings/update":
                    if message["params"].get("serviceTier") is None and not refused:
                        refused = True
                        response = {"id":message["id"], "error":{"code":-32600,"message":"tier change refused"}}
                print(json.dumps(response), flush=True)
            """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let session = try await CodexSession.start(.init(cwd: work, executable: fake))
        try await session.setServiceTier("priority")
        #expect(await session.serviceTier == "priority")
        do {
            try await session.setServiceTier(nil)
            Issue.record("the CLI's refusal must reach the caller")
        } catch CodexAppServer.Failure.rpc(_, let message) {
            #expect(message == "tier change refused")
        }
        #expect(await session.serviceTier == "priority")
        try await session.setServiceTier(nil)
        #expect(await session.serviceTier == nil)
        await session.close()
    }

    @Test func aCodexModelsFastTierIsTheOneNamedFast() throws {
        let model = try json(
            #"{"id":"m","serviceTiers":[{"id":"flex","name":"Flex","description":"slower"},{"id":"priority","name":"Fast","description":"1.5x speed"}]}"#)
        #expect(CodexSession.fastTier(model) == "priority")
        #expect(CodexSession.fastTier(try json(#"{"id":"m","serviceTiers":[]}"#)) == nil)
        #expect(CodexSession.fastTier(try json(#"{"id":"m"}"#)) == nil)
    }
}
