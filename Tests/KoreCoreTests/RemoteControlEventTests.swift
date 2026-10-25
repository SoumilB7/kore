import Foundation
import Testing

@testable import KoreCore

/// The CLIs' own remote control, as their messages say it (shapes from a claude 2.1.312 and a
/// codex 0.159.3 run): the requests that turn it on and off, and the states that follow.
@Suite("CLI remote control messages")
struct RemoteControlEventTests {
    @Test func claudeTurnsItOnWithItsEarlierSessionAndOffWithNothingElse() {
        #expect(ClaudeSession.remoteControl(true, reattach: nil) == ["enabled": true])
        #expect(ClaudeSession.remoteControl(true, reattach: "cse_1") == ["enabled": true, "reattach_session_id": "cse_1"])
        #expect(ClaudeSession.remoteControl(false, reattach: "cse_1") == ["enabled": false])
    }

    @Test func codexAsksForItEphemeralSoNoSettingOutlivesTheAppServer() {
        let on = CodexSession.remoteControl(true)
        let off = CodexSession.remoteControl(false)
        #expect(on.method == "remoteControl/enable" && on.params == ["ephemeral": true])
        #expect(off.method == "remoteControl/disable" && off.params == ["ephemeral": true])
    }

    @Test func claudeReportsItsLinkAsBridgeState() {
        let ready = ClaudeEvent(message: ["type": "system", "subtype": "bridge_state", "state": "ready", "bridge_epoch": 1])
        guard case .bridgeState("ready", nil) = ready else { Issue.record("not a bridge state: \(ready)"); return }
        let failed = ClaudeEvent(message: ["type": "system", "subtype": "bridge_state", "state": "failed", "detail": "offline"])
        guard case .bridgeState("failed", "offline") = failed else { Issue.record("not a failure: \(failed)"); return }
    }

    @Test func anEchoCarriesWhatWasTypedAndWhetherAPersonTypedIt() {
        let typed = ClaudeEvent(message: [
            "type": "user", "isReplay": true, "uuid": "u1", "message": ["role": "user", "content": "Add the check"],
        ])
        guard case .userEcho("u1", let content, false) = typed else { Issue.record("not an echo: \(typed)"); return }
        #expect(content == "Add the check")
        let made = ClaudeEvent(message: ["type": "user", "isReplay": true, "isSynthetic": true, "uuid": "u2", "message": ["content": "x"]])
        guard case .userEcho("u2", _, true) = made else { Issue.record("not synthetic: \(made)"); return }
    }

    @Test func codexReportsItsLinkWithTheNameRemoteClientsSee() {
        let event = CodexEvent(
            notification: "remoteControl/status/changed",
            params: ["status": "connected", "serverName": "acme-mac.local", "installationId": "i", "environmentId": "env_1"])
        guard case .remoteControl("connected", "acme-mac.local", "env_1") = event else { Issue.record("not a status: \(event)"); return }
    }
}
