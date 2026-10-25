import Foundation
import Testing
@testable import KoreCore

@Suite("Pasted login protocol")
struct LoginProtocolTests {
    private func executable(_ text: String, in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("fake-login")
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    @Test(arguments: ["demo-code#current\n", "http://localhost:1455/auth/callback?code=demo-code&state=current"])
    func claudeCallbackAndBrowserWaitFinishTheSameFlow(input: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("login-protocol-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = try executable("""
            #!/usr/bin/python3
            import json,sys
            pending=None
            done=False
            account={"account":{"email":"demo@example.com"}}
            def reply(id,body):
                print(json.dumps({"type":"control_response","response":{"request_id":id,"subtype":"success","response":body}}),flush=True)
            for line in sys.stdin:
                message=json.loads(line)
                request=message['request']
                id=message['request_id']
                kind=request['subtype']
                if kind=='initialize': reply(id,{})
                elif kind=='claude_authenticate':
                    reply(id,{"automaticUrl":"https://example.com/authorize?state=current&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback",
                              "manualUrl":"https://example.com/authorize?state=current&redirect_uri=https%3A%2F%2Fexample.com%2Fcode"})
                elif kind=='claude_oauth_wait_for_completion':
                    if done: reply(id,account)
                    else: pending=id
                elif kind=='claude_oauth_callback':
                    assert request['authorizationCode']=='demo-code' and request['state']=='current'
                    done=True
                    reply(id,account)
                    if pending: reply(pending,account)
            """, in: dir)
        let login = try await ClaudeAuth.Login.start(executable: fake)
        do {
            _ = try await login.begin(["loginWithClaudeAi": true])
            #expect(await login.manualURL?.host == "example.com")
            let waiting = Task { try await login.wait() }
            try await login.submit(input)
            #expect(try await waiting.value["email"]?.string == "demo@example.com")
            await login.cancel()
        } catch { await login.cancel(); throw error }
    }

    @Test func ssoTakesThePastedCodeThroughItsExistingInputPipe() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sso-protocol-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = try executable("""
            #!/usr/bin/python3
            import sys
            print('If the browser didn\\'t open, visit: https://example.com/authorize?state=current',flush=True)
            sys.exit(0 if sys.stdin.readline().strip()=='demo-code#current' else 1)
            """, in: dir)
        let (login, _) = try await ClaudeAuth.SSOLogin.start(executable: fake)
        defer { login.cancel() }
        try login.submit("demo-code#current")
        try await login.wait()
    }
}
