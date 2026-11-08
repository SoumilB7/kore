import Foundation

/// Policy table v1 (phase 18 §1) as data: who may open which service, on which queue and path,
/// with what ability, under which limits. A request no row lists is refused; `PolicyTableTests`
/// walks every row and every combination outside them.
package enum PolicyTable {
    package enum Service: String, Sendable, CaseIterable {
        case link, pipe
        case agentCall = "agent.call"
        case blobPut = "blob.put"
        case raise
    }

    /// Interactive and stream share the ctl connection; bulk is a pipe's own connection.
    package enum Queue: String, Sendable, CaseIterable {
        case interactive, stream, bulk
    }

    package enum Path: String, Sendable, CaseIterable {
        case tailnet, ssh
    }

    /// A limit as data; the layers that serve a service enforce it.
    package enum Limit: Hashable, Sendable {
        case ptys(Int)
        case backlogBytes(Int)
        case pipeArgv
        case concurrent(Int)
        case existingTimeouts
        /// `count` per `seconds`, named after what it counts.
        case rate(String, count: Int, seconds: Int)
        case maxBytes(Int)
        case bytesPerHour(Int)
        case ttlSeconds(Int)
        case singleUse
        case onePerNonce
    }

    /// What the request must carry beyond an ability.
    package enum Proof: Hashable, Sendable {
        case none
        /// A ticket the Mac issued (`pipe.expect`).
        case macTicket
        /// A `kore_raise` signature over the raise digest.
        case signature
    }

    package struct Pair: Hashable, Sendable, CustomStringConvertible {
        package var from: NodeKind
        package var to: NodeKind
        package init(_ from: NodeKind, _ to: NodeKind) {
            self.from = from
            self.to = to
        }
        package var description: String { "\(from.rawValue)→\(to.rawValue)" }
        package static var all: [Pair] { NodeKind.allCases.flatMap { f in NodeKind.allCases.map { Pair(f, $0) } } }
    }

    package struct Row: Hashable, Sendable {
        package var pairs: Set<Pair>
        package var service: Service
        package var queues: Set<Queue>
        package var paths: Set<Path>
        /// The least the caller's record must allow.
        package var needs: Ability
        /// The most the session gets, whatever the record says.
        package var cap: Ability
        package var proof: Proof
        package var limits: [Limit]
    }

    private static let mac = NodeKind.mac, box = NodeKind.box, phone = NodeKind.phone
    private static let everyPair = Set(Pair.all)
    private static let ctl: Set<Queue> = [.interactive, .stream]
    private static let all: Ability = [.read, .ask, .run]

    package static let rows: [Row] = [
        Row(pairs: [Pair(mac, box)], service: .link, queues: ctl, paths: [.tailnet, .ssh], needs: .run, cap: all, proof: .none,
            limits: [.ptys(8), .backlogBytes(8 << 20)]),
        Row(pairs: [Pair(mac, box)], service: .pipe, queues: [.bulk], paths: [.tailnet, .ssh], needs: .run, cap: all, proof: .none,
            limits: [.pipeArgv, .concurrent(2)]),
        // Rides the Mac→box session; the box asks the Mac's tools, under Arsenal's tiers.
        Row(pairs: [Pair(box, mac)], service: .agentCall, queues: [.interactive], paths: [.tailnet, .ssh], needs: .ask, cap: [.read, .ask],
            proof: .none, limits: [.existingTimeouts]),
        Row(pairs: [Pair(phone, mac), Pair(phone, box)], service: .link, queues: ctl, paths: [.tailnet], needs: .read, cap: [.read, .ask],
            proof: .none,
            limits: [
                .rate("messages", count: 20, seconds: 1), .rate("actions", count: 30, seconds: 60), .rate("sends", count: 10, seconds: 60),
                .rate("drafts", count: 8, seconds: 1), .rate("new chats", count: 10, seconds: 3600), .rate("reads", count: 2, seconds: 1),
            ]),
        Row(pairs: Set(NodeKind.allCases.map { Pair(phone, $0) }), service: .blobPut, queues: [.stream], paths: [.tailnet], needs: .ask,
            cap: [.read, .ask], proof: .none, limits: [.maxBytes(12 << 20), .bytesPerHour(blobBytesPerHour)]),
        // The Mac's ticket is the authority; neither box needs a record for the other.
        Row(pairs: [Pair(box, box)], service: .pipe, queues: [.bulk], paths: [.tailnet], needs: [], cap: [], proof: .macTicket,
            limits: [.ttlSeconds(60), .singleUse]),
        Row(pairs: everyPair.subtracting([Pair(mac, mac)]), service: .raise, queues: [.interactive], paths: [.tailnet], needs: .ask,
            cap: [.read, .ask], proof: .signature, limits: [.onePerNonce]),
    ]

    /// The phone's blob bytes per hour (§1 names a cap without a number): 256 MiB until the
    /// owner picks one.
    package static let blobBytesPerHour = 256 << 20

    package struct Request: Hashable, Sendable {
        package var pair: Pair
        package var service: Service
        package var queue: Queue
        package var path: Path
        /// The caller's record (empty when it has none, as for a ticketed box).
        package var abilities: Ability
        package var proof: Proof

        package init(pair: Pair, service: Service, queue: Queue, path: Path, abilities: Ability, proof: Proof = .none) {
            self.pair = pair
            self.service = service
            self.queue = queue
            self.path = path
            self.abilities = abilities
            self.proof = proof
        }
    }

    package enum Decision: Equatable, Sendable {
        /// Allowed under `row`, with `granted` (the record's abilities within the row's cap).
        case allow(row: Row, granted: Ability)
        case unlisted
        case ability
        case proof
    }

    package static func decide(_ request: Request) -> Decision {
        guard let row = rows.first(where: {
            $0.pairs.contains(request.pair) && $0.service == request.service && $0.queues.contains(request.queue) && $0.paths.contains(request.path)
        }) else { return .unlisted }
        guard request.abilities.allows(row.needs) else { return .ability }
        guard row.proof == .none || request.proof == row.proof else { return .proof }
        return .allow(row: row, granted: request.abilities.effective.intersection(row.cap.effective))
    }
}
