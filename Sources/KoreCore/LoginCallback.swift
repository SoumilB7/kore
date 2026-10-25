import Foundation

/// Short-lived OAuth input. Parsed values never belong in settings, logs or error messages.
public enum LoginCallback {
    public struct Code: Sendable, Equatable {
        public let authorizationCode: String
        public let state: String
    }

    public enum Failure: LocalizedError {
        case invalid, wrongFlow, unavailable, unreachable
        public var errorDescription: String? {
            switch self {
            case .invalid: "Paste the full sign-in code or callback URL."
            case .wrongFlow: "This belongs to a different sign-in. Use the current sign-in page."
            case .unavailable: "This sign-in has ended. Start again."
            case .unreachable: "Couldn't finish through localhost. Try again or use Device Code."
            }
        }
    }

    public static func code(_ input: String, authorizationURL: URL) throws -> Code {
        let expected = try value("state", in: authorizationURL)
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 16_384 else { throw Failure.invalid }
        let result: Code
        if text.contains("://") {
            let url = try matchingCallback(text, authorizationURL: authorizationURL)
            result = Code(authorizationCode: try value("code", in: url), state: try value("state", in: url))
        } else {
            let parts = text.split(separator: "#", omittingEmptySubsequences: false)
            guard parts.count == 1 || parts.count == 2 else { throw Failure.invalid }
            result = Code(authorizationCode: String(parts[0]), state: parts.count == 2 ? String(parts[1]) : expected)
        }
        guard token(result.authorizationCode), token(result.state) else { throw Failure.invalid }
        guard result.state == expected else { throw Failure.wrongFlow }
        return result
    }

    /// Only the exact callback advertised by this login can receive a pasted URL.
    public static func localhostURL(_ input: String, authorizationURL: URL) throws -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 16_384 else { throw Failure.invalid }
        let url = try matchingCallback(text, authorizationURL: authorizationURL)
        guard url.scheme == "http", let host = url.host?.lowercased(), ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host),
              let port = url.port, (1...65535).contains(port) else { throw Failure.invalid }
        _ = try code(text, authorizationURL: authorizationURL)
        return url
    }

    public static func finishLocalhost(_ input: String, authorizationURL: URL) async throws {
        let url = try localhostURL(input, authorizationURL: authorizationURL)
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { throw Failure.unreachable }
        } catch { throw Failure.unreachable }
    }

    private static func matchingCallback(_ text: String, authorizationURL: URL) throws -> URL {
        guard let url = URL(string: text), let expected = URL(string: try value("redirect_uri", in: authorizationURL)),
              url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme?.lowercased() == expected.scheme?.lowercased(), url.host?.lowercased() == expected.host?.lowercased(),
              url.port == expected.port, url.path == expected.path else { throw Failure.invalid }
        return url
    }

    private static func value(_ name: String, in url: URL) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == name } ?? []
        guard items.count == 1, let value = items.first?.value, !value.isEmpty else { throw Failure.invalid }
        return value
    }

    private static func token(_ text: String) -> Bool {
        !text.isEmpty && !text.contains(where: { $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true })
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
