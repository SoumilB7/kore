import Foundation
import Testing
@testable import KoreCore

@Suite("Login callback input")
struct LoginCallbackTests {
    static let auth = URL(string: "https://example.com/authorize?state=current&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback")!

    @Test func claudeCodesKeepTheirStateAndTrimPasteNewlines() throws {
        let code = try LoginCallback.code("  demo-code#current\n", authorizationURL: Self.auth)
        #expect(code.authorizationCode == "demo-code" && code.state == "current")
        #expect(try LoginCallback.code("demo-code", authorizationURL: Self.auth) == code)
        #expect(throws: LoginCallback.Failure.self) { try LoginCallback.code("demo-code#older", authorizationURL: Self.auth) }
    }

    @Test func callbackUsesOnlyTheListenerAndStateOfThisLogin() throws {
        let url = "http://localhost:1455/auth/callback?code=demo&state=current"
        #expect(try LoginCallback.localhostURL(url + "\n", authorizationURL: Self.auth).absoluteString == url)
        #expect(try LoginCallback.code(url, authorizationURL: Self.auth).authorizationCode == "demo")
        let invalid = [
            url.replacingOccurrences(of: "current", with: "previous"),
            url.replacingOccurrences(of: "localhost", with: "evil.example"),
            url.replacingOccurrences(of: "localhost", with: "localhost.evil.example"),
            url.replacingOccurrences(of: "localhost", with: "127.0.0.1"),
            url.replacingOccurrences(of: "1455", with: "9000"),
            url.replacingOccurrences(of: "/auth/callback", with: "/stop"),
            url.replacingOccurrences(of: "http:", with: "https:"),
            url.replacingOccurrences(of: "localhost", with: "user@localhost"),
            url + "&state=current", url + "&code=second", url + "#fragment",
            "http://localhost:1455/auth/callback?error=denied&state=current", "demo-code#current",
        ]
        for text in invalid {
            #expect(throws: LoginCallback.Failure.self) { try LoginCallback.localhostURL(text, authorizationURL: Self.auth) }
        }
    }

    @Test func invalidAndOversizedCodesAreRejected() {
        for text in ["", "   ", "#current", "code#", "code#current#extra", "code\n#current", String(repeating: "x", count: 16_385)] {
            #expect(throws: LoginCallback.Failure.self) { try LoginCallback.code(text, authorizationURL: Self.auth) }
        }
        for auth in ["https://example.com", "https://example.com?state=one&state=two", "https://example.com?state="] {
            #expect(throws: LoginCallback.Failure.self) { try LoginCallback.code("code", authorizationURL: URL(string: auth)!) }
        }
    }

    @Test func nonLoopbackRedirectsCannotReceiveCodexInputs() {
        let auth = URL(string: "https://example.com?state=current&redirect_uri=https%3A%2F%2Fexample.com%2Fcallback")!
        #expect(throws: LoginCallback.Failure.self) {
            try LoginCallback.localhostURL("https://example.com/callback?code=demo&state=current", authorizationURL: auth)
        }
    }
    @Test func localhostSubmissionStopsAtRedirectAndNeverFollowsIt() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", """
        from http.server import HTTPServer, BaseHTTPRequestHandler
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                print(self.path.split('?')[0], flush=True)
                self.send_response(302)
                self.send_header('Location', '/must-not-follow')
                self.end_headers()
            def log_message(self, *args): pass
        server = HTTPServer(('127.0.0.1', 0), Handler)
        print(server.server_port, flush=True)
        server.serve_forever()
        """]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        // The whole port line: under load its newline can arrive in a later read.
        var head = Data()
        while !head.contains(UInt8(ascii: "\n")) {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            head.append(chunk)
        }
        let line = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let port = try #require(Int(line))
        var auth = URLComponents(string: "https://example.com/authorize")!
        auth.queryItems = [URLQueryItem(name: "state", value: "current"),
                           URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1:\(port)/auth/callback")]
        try await LoginCallback.finishLocalhost("http://127.0.0.1:\(port)/auth/callback?code=demo&state=current", authorizationURL: auth.url!)
        process.terminate()
        process.waitUntilExit()
        let requests = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(requests == "/auth/callback\n")
    }

}
