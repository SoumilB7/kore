import Foundation
import Testing

@testable import KoreCore

/// What Kore reads of each CLI's login, and what it never passes on.
@Suite("Auth")
struct AuthTests {
    @Test func claudesStatus() {
        let status = ClaudeAuth.Status([
            "loggedIn": true, "authMethod": "api_key", "apiKeySource": "/login managed key", "apiProvider": "firstParty",
            "forcedLoginMethod": "console", "email": "you@example.com", "orgName": "Acme Labs",
        ])
        #expect(status.loggedIn && status.authMethod == "api_key" && status.apiKeySource == "/login managed key")
        #expect(status.forcedLoginMethod == "console" && status.apiProvider == "firstParty" && status.orgName == "Acme Labs")
        #expect(!ClaudeAuth.Status(["authMethod": "none"]).loggedIn)
    }

    @Test func claudesSignInPageIsTheAutomaticOne() {
        let reply: JSONValue = [
            "manualUrl": "https://platform.claude.com/oauth/code/callback?x=1", "automaticUrl": "https://claude.ai/oauth/authorize?y=2",
        ]
        #expect(ClaudeAuth.automaticURL(reply)?.host() == "claude.ai")
        #expect(ClaudeAuth.automaticURL(["automaticUrl": "file:///etc/passwd"]) == nil)
        #expect(ClaudeAuth.automaticURL(["manualUrl": "https://claude.ai"]) == nil)
    }

    @Test func claudesLogoutReason() {
        #expect(ClaudeAuth.logoutReason("Logout failed: network unreachable\n") == "network unreachable")
        #expect(ClaudeAuth.logoutReason("\nsomething else\nmore") == "something else")
        #expect(ClaudeAuth.logoutReason("") == nil)
    }

    /// Only `oauthAccount` counts: the rest of the file changes all the time.
    @Test func claudesAccountStamp() {
        let a = Data(#"{"numStartups": 3, "oauthAccount": {"emailAddress": "you@example.com", "accountUuid": "1"}}"#.utf8)
        let b = Data(#"{"oauthAccount": {"accountUuid": "1", "emailAddress": "you@example.com"}, "numStartups": 4}"#.utf8)
        let c = Data(#"{"oauthAccount": {"accountUuid": "2", "emailAddress": "work@acme.dev"}}"#.utf8)
        #expect(ClaudeAuth.accountStamp(a) == ClaudeAuth.accountStamp(b))
        #expect(ClaudeAuth.accountStamp(a) != ClaudeAuth.accountStamp(c))
        #expect(ClaudeAuth.accountStamp(Data(#"{"numStartups": 3}"#.utf8)) == "")
        #expect(ClaudeAuth.accountStamp(Data("not json".utf8)) == nil)
    }

    @Test func theLoginFilesFollowTheirStores() {
        #expect(ClaudeAuth.configFile(environment: ["CLAUDE_CONFIG_DIR": "/tmp/c"]).path == "/tmp/c/.claude.json")
        #expect(ClaudeAuth.configFile(environment: [:]).lastPathComponent == ".claude.json")
        #expect(CodexAuth.authFile(environment: ["CODEX_HOME": "/tmp/x"]).path == "/tmp/x/auth.json")
        #expect(CodexAuth.authFile(environment: [:]).path.hasSuffix("/.codex/auth.json"))
    }

    @Test func codexsStatus() {
        let status = CodexAuth.Status(["account": ["type": "chatgpt", "email": "you@example.com", "planType": "pro"], "requiresOpenaiAuth": true])
        #expect(status.loggedIn && status.type == "chatgpt" && status.planType == "pro")
        let out = CodexAuth.Status(["account": nil, "requiresOpenaiAuth": false])
        #expect(!out.loggedIn && !out.requiresOpenaiAuth)
    }

    @Test func codexsSignInPrompt() {
        let browser = CodexAuth.Prompt(["type": "chatgpt", "loginId": "l1", "authUrl": "https://auth.openai.com/oauth/authorize?s=1"])
        #expect(browser?.loginId == "l1" && browser?.url.host() == "auth.openai.com" && browser?.userCode == nil)
        let device = CodexAuth.Prompt([
            "type": "chatgptDeviceCode", "loginId": "l2", "verificationUrl": "https://auth.openai.com/codex/device", "userCode": "K7QM-4XWD",
        ])
        #expect(device?.userCode == "K7QM-4XWD")
        #expect(CodexAuth.Prompt(["authUrl": "https://auth.openai.com"]) == nil)
        #expect(CodexAuth.Prompt(["loginId": "l3", "authUrl": "javascript:alert(1)"]) == nil)
    }

    @Test func codexsSignInEnd() {
        #expect(CodexAuth.Completion(["loginId": "l1", "success": true, "error": nil], loginId: "l1") == .succeeded)
        #expect(CodexAuth.Completion(["loginId": "l1", "success": false, "error": "Login cancelled"], loginId: "l1") == .failed("Login cancelled"))
        #expect(CodexAuth.Completion(["loginId": "l1", "success": false, "error": ""], loginId: "l1") == .failed(nil))
        // Another login's end (one started elsewhere) isn't this one's.
        #expect(CodexAuth.Completion(["loginId": "l9", "success": true], loginId: "l1") == nil)
    }

    @Test func codexsRefusedLogin() {
        #expect(CodexError.isUnauthorized(["message": "401", "codexErrorInfo": "unauthorized"]))
        #expect(CodexError.isUnauthorized(["codexErrorInfo": ["responseStreamDisconnected": ["httpStatusCode": 401]]]))
        #expect(!CodexError.isUnauthorized(["codexErrorInfo": ["httpConnectionFailed": ["httpStatusCode": 500]]]))
        #expect(!CodexError.isUnauthorized(["codexErrorInfo": "usageLimitExceeded"]))
        #expect(!CodexError.isUnauthorized(nil))
    }

    @Test func claudesRefusedLoginIsItsOwnEvent() {
        let message: JSONValue = [
            "type": "assistant", "error": "authentication_failed", "parent_tool_use_id": nil,
            "message": ["id": "m1", "content": [["type": "text", "text": "Not logged in · Please run /login"]]],
        ]
        guard case .authFailed(let said) = ClaudeEvent(message: message) else { Issue.record("not authFailed"); return }
        #expect(said == "Not logged in · Please run /login")
        var other = message
        if case .object(var fields) = other {
            fields["error"] = "rate_limit"
            other = .object(fields)
        }
        guard case .assistant = ClaudeEvent(message: other) else { Issue.record("not assistant"); return }
    }

    /// Credentials from the env never reach a CLI Kore starts; what only moves the stores does.
    @Test func foreignCredentialsAreStripped() {
        let stripped = Set(CLIExecutable.foreignAuthVariables)
        for name in ["CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CODEX_ACCESS_TOKEN", "ANTHROPIC_API_KEY", "OPENAI_API_KEY"] {
            #expect(stripped.contains(name))
        }
        #expect(!stripped.contains("CLAUDE_CONFIG_DIR"))
        #expect(!stripped.contains("CODEX_HOME"))
    }

    /// The activation check lets one read through per 30 s.
    @Test func theActivationCheckIsThrottled() {
        var throttle = Throttle(interval: 30)
        let start = Date(timeIntervalSince1970: 1_000)
        let passes = [0, 10, 29.9, 30, 31].map { throttle.pass(at: start.addingTimeInterval($0)) }
        #expect(passes == [true, false, false, true, false])
    }
}
