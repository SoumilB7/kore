import Foundation

/// What a phone may do on its live link, over time: alerts only (WATCH) until a step-up signed
/// with its act key gives full access (FULL); FULL ends on lock, screen-off or background, after
/// 5 minutes idle or 30 in all. Answers are authorized only by the act key's signature over
/// them, on this session. Pings, and the session's own lifetime, run here too.
enum LinkAccess {
    static let fullIdle: TimeInterval = 300
    static let fullMax: TimeInterval = 1800
    static let watchMax: TimeInterval = 6 * 3600
    static let sessionMax: TimeInterval = 24 * 3600
    /// Activity that keeps FULL from idling.
    static let actions: Set<String> = ["cmd", "tx.open", "tx.more", "tx.close", "entry.more"]

    typealias Full = Locked<(since: Date, last: Date)?>

    static func wire(_ link: SecureLink, phone: PhoneRecord, gate: RemoteGate) {
        let actKey = KoreKeys.actKey(phone.actKey)
        let hash = link.handshakeHash
        let full = Full(nil)
        link.onControl { control in
            switch control.t {
            case "link.stepup.req":
                let nonce = KoreKeys.random(32)
                Task { await gate.challenge(link, nonce) }
                var c = LinkControl("link.stepup.chal")
                c.nonce = nonce.base64EncodedString()
                link.sendControl(c)
            case "link.stepup":
                Task {
                    let nonce = await gate.takeChallenge(link)
                    guard let nonce, let actKey, let sig = control.sig.flatMap({ Data(base64Encoded: $0) }),
                        KoreKeys.verify(sig, KoreKeys.stepUpMessage(hash, nonce: nonce), actKey)
                    else {
                        await gate.note("step-up-refused", ["phone": phone.id])
                        level(link, .watch)
                        return
                    }
                    full.withLock { $0 = (Date(), Date()) }
                    link.setAccess(.full)
                    level(link, .full)
                    await gate.note("unlocked", ["phone": phone.id])
                }
            case "link.lock":
                drop(link, full)
            case "link.state":
                if control.screen == false || control.app == "background" { drop(link, full) }
            default:
                break
            }
        }
        link.onInbound { type in
            guard actions.contains(type) else { return }
            full.withLock { if $0 != nil { $0!.last = Date() } }
        }
        link.setAuthorizer { proof in
            guard link.access == .full, let actKey, let digest = Data(hexString: proof.digest), let sig = Data(base64Encoded: proof.sig) else {
                return false
            }
            return KoreKeys.verify(sig, KoreKeys.approveMessage(hash, cardId: proof.cardId, digest: digest, action: proof.action), actKey)
        }
        link.onEnd { _ in Task { await gate.linkEnded(phone.id, link) } }
        clocks(link, full)
    }

    /// FULL's clocks, the session's lifetime, and pings (30 s open, 180 s in the background).
    private static func clocks(_ link: SecureLink, _ full: Full) {
        let started = Date()
        Task.detached {
            var tick: UInt64 = 0
            while !link.isClosed {
                try? await Task.sleep(for: .seconds(5))
                let t = Date()
                if let f = full.withLock({ $0 }), t.timeIntervalSince(f.last) > fullIdle || t.timeIntervalSince(f.since) > fullMax {
                    drop(link, full)
                }
                let age = t.timeIntervalSince(started)
                if age > sessionMax || (age > watchMax && link.access == .watch) {
                    link.bye(.expired)
                    return
                }
                tick += 1
                let every: UInt64 = link.access == .full ? 6 : 36
                if tick % every == 0 { link.ping(tick) }
                if t.timeIntervalSince(link.lastInbound) > Double(every * 5 * 3 + 10) {
                    link.bye(.expired)
                    return
                }
            }
        }
    }

    private static func level(_ link: SecureLink, _ access: RemoteAccess) {
        var c = LinkControl("link.level")
        c.level = access.rawValue
        link.sendControl(c)
    }

    private static func drop(_ link: SecureLink, _ full: Full) {
        let was = full.withLock { f -> Bool in
            defer { f = nil }
            return f != nil
        }
        guard was else { return }
        link.setAccess(.watch)
        level(link, .watch)
    }
}
