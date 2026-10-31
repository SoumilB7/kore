import Foundation

/// The phone's side of the relay, as a byte channel: joins the Mac's mailbox with its token, and
/// knows whether the Mac is there (`present`). Kotlin does the same on the phone; this one is
/// for the probe, the tests and the storylines.
package final class RelayPhoneChannel: ByteChannel, @unchecked Sendable {
    private let socket: any RelaySocket
    private let state = Locked<(present: Bool, buffered: [Data])>((false, []))
    private let onPresence: (@Sendable (Bool) -> Void)?

    private init(_ socket: any RelaySocket, onPresence: (@Sendable (Bool) -> Void)?) {
        self.socket = socket
        self.onPresence = onPresence
    }

    package static func join(
        _ dial: RelayDialer, mailbox: Data, token: Data, onPresence: (@Sendable (Bool) -> Void)? = nil
    ) async throws -> RelayPhoneChannel {
        RelayPhoneChannel(try await dial(mailbox, .phone, token), onPresence: onPresence)
    }

    package var remoteHost: String { "relay" }
    /// Whether the relay says the Mac is connected.
    package var present: Bool { state.withLock { $0.present } }

    package func receive() async throws -> Data {
        while true {
            let bytes = try await socket.receive()
            guard let frame = RelayFrame(bytes, host: false) else { throw ChannelError.closed }
            switch frame {
            case .data(_, let payload): return payload
            case .open:
                state.withLock { $0.present = true }
                onPresence?(true)
            case .close:
                state.withLock { $0.present = false }
                onPresence?(false)
            default: throw ChannelError.closed
            }
        }
    }

    package func send(_ data: Data) async throws {
        var offset = data.startIndex
        repeat {
            let end = min(offset + RelayFrame.maxPayload, data.endIndex)
            try await socket.send(RelayFrame.data(slot: nil, Data(data[offset..<end])).encoded(host: false))
            offset = end
        } while offset < data.endIndex
    }

    package func close() { socket.close() }
}
