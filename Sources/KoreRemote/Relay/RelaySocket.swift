import Foundation

/// One WebSocket to the relay (or the loopback relay's stand-in): whole binary messages.
package protocol RelaySocket: AnyObject, Sendable {
    func send(_ data: Data) async throws
    /// The next message; throws once the socket is closed.
    func receive() async throws -> Data
    func close()
}

/// Opens a socket to a mailbox, as `role`, with `token`; throws `RelayJoin.Refusal` when the
/// relay turns it away. The real one dials the relay; tests and storylines use the loopback.
package typealias RelayDialer = @Sendable (_ mailbox: Data, _ role: RelayJoin.Role, _ token: Data) async throws -> any RelaySocket

/// A WebSocket to the real relay, `wss://<host>/m/<mailbox>`, the token in a header (never the
/// URL, which logs keep).
package final class WebSocketRelay: RelaySocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    private init(_ task: URLSessionWebSocketTask) { self.task = task }

    /// A dialer for the relay at `host`.
    package static func dialer(host: String) -> RelayDialer {
        { mailbox, role, token in
            guard let url = URL(string: "wss://\(host)\(RelayJoin.path(mailbox))") else { throw RelayJoin.Refusal.notFound }
            var request = URLRequest(url: url)
            request.setValue(role.rawValue, forHTTPHeaderField: "X-Kore-Role")
            request.setValue("Bearer " + token.base64URL, forHTTPHeaderField: "Authorization")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            configuration.httpCookieStorage = nil
            let session = URLSession(configuration: configuration)
            let task = session.webSocketTask(with: request)
            task.maximumMessageSize = RelayFrame.maxSize
            task.resume()
            let socket = WebSocketRelay(task)
            // The upgrade's answer: a refusal shows as the first receive failing.
            try await withDeadline(15) { try await socket.ready() }
            return socket
        }
    }

    private func ready() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if error == nil {
                    done.resume()
                } else {
                    let status = (self.task.response as? HTTPURLResponse)?.statusCode ?? 0
                    done.resume(throwing: RelayJoin.Refusal(rawValue: status) ?? ChannelError.closed)
                }
            }
        }
    }

    package func send(_ data: Data) async throws { try await task.send(.data(data)) }

    package func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string: throw ChannelError.closed
        @unknown default: throw ChannelError.closed
        }
    }

    package func close() { task.cancel(with: .normalClosure, reason: nil) }
}
