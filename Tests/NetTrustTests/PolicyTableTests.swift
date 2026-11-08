import Foundation
import KoreTrust
import Testing

/// Policy table v1, walked whole: every pair × service × queue × path × ability × proof, against
/// the plan's table written out again here. Listed rows allow exactly what they say; everything
/// else, Mac→Mac included, is unlisted and refused.
@Suite("policy table")
struct PolicyTableTests {
    typealias P = PolicyTable

    /// Plan §1 "Policy table v1", as text.
    struct Planned {
        var pairs: [String]
        var service: String
        var queues: [String]
        var paths: [String]
        var needs: Ability
        var cap: Ability
        var proof: P.Proof
    }

    static let plan: [Planned] = [
        Planned(pairs: ["mac→box"], service: "link", queues: ["interactive", "stream"], paths: ["tailnet", "ssh"], needs: .run, cap: [.read, .ask, .run], proof: .none),
        Planned(pairs: ["mac→box"], service: "pipe", queues: ["bulk"], paths: ["tailnet", "ssh"], needs: .run, cap: [.read, .ask, .run], proof: .none),
        Planned(pairs: ["box→mac"], service: "agent.call", queues: ["interactive"], paths: ["tailnet", "ssh"], needs: .ask, cap: [.read, .ask], proof: .none),
        Planned(pairs: ["phone→mac", "phone→box"], service: "link", queues: ["interactive", "stream"], paths: ["tailnet"], needs: .read, cap: [.read, .ask], proof: .none),
        Planned(pairs: ["phone→mac", "phone→box", "phone→phone"], service: "blob.put", queues: ["stream"], paths: ["tailnet"], needs: .ask, cap: [.read, .ask], proof: .none),
        Planned(pairs: ["box→box"], service: "pipe", queues: ["bulk"], paths: ["tailnet"], needs: [], cap: [], proof: .macTicket),
        Planned(
            pairs: ["mac→box", "mac→phone", "box→mac", "box→box", "box→phone", "phone→mac", "phone→box", "phone→phone"], service: "raise",
            queues: ["interactive"], paths: ["tailnet"], needs: .ask, cap: [.read, .ask], proof: .signature),
    ]

    static let holdings: [Ability] = [[], .read, [.read, .ask], .run]

    func planned(_ r: P.Request) -> Planned? {
        Self.plan.first {
            $0.pairs.contains(r.pair.description) && $0.service == r.service.rawValue && $0.queues.contains(r.queue.rawValue) && $0.paths.contains(r.path.rawValue)
        }
    }

    @Test func everyCombinationMatchesThePlan() {
        var allowed = 0, unlisted = 0
        for pair in P.Pair.all {
            for service in P.Service.allCases {
                for queue in P.Queue.allCases {
                    for path in P.Path.allCases {
                        for held in Self.holdings {
                            for proof in [P.Proof.none, .macTicket, .signature] {
                                let request = P.Request(pair: pair, service: service, queue: queue, path: path, abilities: held, proof: proof)
                                let decision = P.decide(request)
                                guard let row = planned(request) else {
                                    #expect(decision == .unlisted, "\(pair) \(service) \(queue) \(path)")
                                    unlisted += 1
                                    continue
                                }
                                let ok = held.effective.isSuperset(of: row.needs) && (row.proof == .none || proof == row.proof)
                                if ok {
                                    guard case .allow(_, let granted) = decision else {
                                        Issue.record("\(pair) \(service) \(queue) \(path) \(held.names) refused: \(decision)")
                                        continue
                                    }
                                    #expect(granted == held.effective.intersection(row.cap))
                                    allowed += 1
                                } else {
                                    #expect(decision == (held.effective.isSuperset(of: row.needs) ? .proof : .ability), "\(pair) \(service) \(held.names)")
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(allowed > 0 && unlisted > 0)
    }

    /// The table holds exactly the plan's rows, each with the plan's limits.
    @Test func rowsAndLimitsAreThePlans() {
        #expect(P.rows.count == Self.plan.count)
        func limits(_ pair: String, _ service: P.Service) -> [P.Limit] {
            P.rows.first { $0.service == service && $0.pairs.contains { $0.description == pair } }?.limits ?? []
        }
        #expect(limits("mac→box", .link) == [.ptys(8), .backlogBytes(8 << 20)])
        #expect(limits("mac→box", .pipe) == [.pipeArgv, .concurrent(2)])
        #expect(limits("box→mac", .agentCall) == [.existingTimeouts])
        #expect(limits("phone→box", .link) == [
            .rate("messages", count: 20, seconds: 1), .rate("actions", count: 30, seconds: 60), .rate("sends", count: 10, seconds: 60),
            .rate("drafts", count: 8, seconds: 1), .rate("new chats", count: 10, seconds: 3600), .rate("reads", count: 2, seconds: 1),
        ])
        #expect(limits("phone→mac", .blobPut) == [.maxBytes(12 << 20), .bytesPerHour(P.blobBytesPerHour)])
        #expect(limits("box→box", .pipe) == [.ttlSeconds(60), .singleUse])
        #expect(limits("phone→box", .raise) == [.onePerNonce])
    }

    @Test(arguments: [
        P.Request(pair: .init(.mac, .mac), service: .link, queue: .interactive, path: .tailnet, abilities: .run),
        P.Request(pair: .init(.mac, .mac), service: .raise, queue: .interactive, path: .tailnet, abilities: .run, proof: .signature),
        P.Request(pair: .init(.phone, .phone), service: .link, queue: .interactive, path: .tailnet, abilities: .run),
        P.Request(pair: .init(.box, .phone), service: .link, queue: .interactive, path: .tailnet, abilities: .run),
        P.Request(pair: .init(.phone, .box), service: .link, queue: .interactive, path: .ssh, abilities: .run),
        P.Request(pair: .init(.phone, .box), service: .pipe, queue: .bulk, path: .tailnet, abilities: .run),
        P.Request(pair: .init(.box, .box), service: .pipe, queue: .bulk, path: .ssh, abilities: .run, proof: .macTicket),
        P.Request(pair: .init(.mac, .box), service: .link, queue: .bulk, path: .tailnet, abilities: .run),
    ])
    func unlistedIsRefused(_ request: P.Request) {
        #expect(P.decide(request) == .unlisted)
    }

    @Test func phoneWithRunIsStillCappedAtReadAsk() {
        let request = P.Request(pair: .init(.phone, .mac), service: .link, queue: .stream, path: .tailnet, abilities: .run)
        guard case .allow(_, let granted) = P.decide(request) else {
            Issue.record("refused")
            return
        }
        #expect(granted == [.read, .ask])
    }
}
