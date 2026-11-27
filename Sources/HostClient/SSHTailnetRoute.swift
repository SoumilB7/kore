import Foundation
import KoreCore
import KoreTrust
import Synchronization
import Tailnet

/// SSH to a box at a tailnet address follows the tailnet, whatever its state (KoreNet review
/// item 3). An alias whose host is a tailnet address (`100.x`, `fd7a:115c:a1e0::`, or a MagicDNS
/// name) rides one node of the box: when that node is offline (the box's Tailscale stopped, so
/// its own node carries it) the same box's other node is used, the one online now, named
/// `<name>` or `<name>-kore` for the same user; and while Kore's own tailnet carries this Mac
/// (installed Tailscale quit or gone, so no route for the address), ssh goes through it
/// (`kore-tailnet nc`). The box's known host key is kept (`HostKeyAlias`); sshd still
/// authenticates. A host that isn't a tailnet address, or a jump host's route, is left as the
/// user set it. Read fresh off the main actor (a local socket's answer); on it, the last answer.
package enum SSHTailnetRoute {
    /// This Mac's tailnet now, as KoreNet chose it: its client, and Kore's own helper and socket
    /// when it's Kore's own.
    package struct Current: @unchecked Sendable {
        package var tailnet: any Tailnet
        package var own: (helper: String, socket: String)?

        package init(tailnet: any Tailnet, own: (helper: String, socket: String)?) {
            self.tailnet = tailnet
            self.own = own
        }
    }

    private static let current = Mutex<Current?>(nil)
    /// The node each box's KoreNet link is up on now, by the box's SSH alias: reachable this
    /// moment, whatever the control server still lists online (it's seconds late).
    private static let live = Mutex<[String: String]>([:])
    /// This Mac's tailnet status as KoreNet last heard it (its bus and its reads): what an SSH
    /// launched on the main actor decides from, with no socket round trip there.
    private static let lastStatus = Mutex<TailnetStatus?>(nil)
    /// The route last said in hosts.log, per alias.
    private static let said = Mutex<[String: String]>([:])
    /// Posted at each change to what routes come out (KoreNet chose another tailnet, a box's link
    /// came up on a node): a sync paused on an unreachable box tries again (`HostSync`).
    package static let changed = Notification.Name("SSHTailnetRoute.changed")
    private static func announce() { NotificationCenter.default.post(name: changed, object: nil) }

    /// `ssh -G` per alias, briefly (one process per spawn otherwise).
    private static let resolved = Mutex<[String: (at: Date, host: String, jump: Bool, keyAlias: Bool)]>([:])

    /// KoreNet chose (nil: off, or nothing chosen): what each ssh after this rides.
    package static func set(_ now: Current?) {
        current.withLock { $0 = now }
        lastStatus.withLock { $0 = nil }
        announce()
    }

    /// A box's KoreNet link came up on `node` (nil: it ended).
    package static func linked(_ alias: String, node: String?) {
        let before = live.withLock { nodes -> String? in
            let old = nodes[alias]
            nodes[alias] = node
            return old
        }
        if before != node, node != nil { announce() }
    }

    /// KoreNet heard this Mac's tailnet status.
    package static func heard(_ status: TailnetStatus?) { lastStatus.withLock { $0 = status } }

    /// Off in test processes: their ssh is a fake, and `ssh -G` would read the user's config.
    nonisolated(unsafe) package static var resolves = !KoreLog.isTestProcess

    /// The extra `-o` options for `alias` now ([] when nothing changes): decided afresh for each
    /// ssh. Off the main actor its status is read now; on it, the status KoreNet last heard (no
    /// socket round trip there). Either way the node the box's link is on now comes first.
    package static func options(for alias: String) -> [String] {
        guard resolves, let now = current.withLock({ $0 }), let found = resolve(alias) else { return [] }
        let status = Thread.isMainThread ? lastStatus.withLock({ $0 }) : (try? now.tailnet.status()) ?? lastStatus.withLock({ $0 })
        let made = decide(
            host: found.host, jump: found.jump, keyAlias: found.keyAlias, status: status, own: now.own, live: live.withLock { $0[alias] })
        // Said when it changes: a sync spawns ssh many times a round.
        let line = made.filter { !$0.hasPrefix("-") }.joined(separator: " ")
        if !made.isEmpty, said.withLock({ $0.updateValue(line, forKey: alias) }) != line { HostLog.note(alias, "ssh route", line) }
        return made
    }

    /// The same, worked out off the main actor (`ssh -G`, a status read): what an async caller uses.
    package static func options(forAlias alias: String) async -> [String] {
        // Nothing to route (KoreNet off, or a test process): no hop at all.
        guard resolves, current.withLock({ $0 }) != nil else { return [] }
        return await Task.detached(priority: .userInitiated) { options(for: alias) }.value
    }

    /// Where SSH to `host` goes now: the address (nil: as the alias says) and the ssh options.
    package struct Route: Equatable, Sendable {
        package var target: String?
        package var options: [String]
    }

    /// The decision, as a pure function of the alias's host, the tailnet's status and the box's
    /// known nodes online now (`known`, `BoxNodes.candidates`, for an enrolled box): the one rule
    /// every SSH to a box follows. The alias's node online: as it is. Offline: the box's other
    /// node, installed Tailscale's first (sshd on its kernel interface), then Kore's own (its
    /// port 22 is the box's sshd, `OwnSSHForward`), then one found by name. This Mac on Kore's
    /// own tailnet: through it (`kore-tailnet nc`).
    package static func route(
        host: String, jump: Bool, keyAlias: Bool, status: TailnetStatus?, own: (helper: String, socket: String)?, known: [BoxNodes.Candidate] = [],
        live: String? = nil
    ) -> Route {
        let options = decide(host: host, jump: jump, keyAlias: keyAlias, status: status, own: own, known: known, live: live)
        let target = zip(options, options.dropFirst()).first { $0.0 == "-o" && $0.1.hasPrefix("HostName=") }.map { String($0.1.dropFirst(9)) }
        return Route(target: target == IPAddress(host)?.description || target == host ? nil : target, options: options)
    }

    /// `live`: the node key the box's KoreNet link is up on now, which beats any online flag.
    package static func decide(
        host: String, jump: Bool, keyAlias: Bool, status: TailnetStatus?, own: (helper: String, socket: String)?, known: [BoxNodes.Candidate] = [],
        live: String? = nil
    ) -> [String] {
        guard !jump, let status else { return [] }
        let ip = IPAddress(host)
        // A MagicDNS name: under this tailnet's own suffix (its node's name, less the first label).
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let suffix = status.selfNode.map { $0.dnsName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".").dropFirst().joined(separator: ".") } ?? ""
        let magic = ip == nil && (name.hasSuffix(".ts.net") || (!suffix.isEmpty && name.hasSuffix("." + suffix)))
        guard ip?.isTailnet == true || magic else { return [] }
        // The box's node the alias names, and its sibling (same owner, `<name>` / `<name>-kore`).
        let named = status.peers.first { peer in
            if let ip { return peer.tailscaleIPs.contains { IPAddress($0) == ip } }
            return sameName(peer.hostName, host)
        }
        var target = ip.map(\.description) ?? host
        let namedOnline = named?.online == true
        // An enrolled box's own known nodes come first: installed Tailscale's, then Kore's own.
        let ranked = known.filter { !BoxNodes.isOwnNode($0.name) } + known.filter { BoxNodes.isOwnNode($0.name) }
        // The box's link is up on one of its nodes this moment: that node, as it's proven reachable
        // (its own node's port 22 is the box's sshd).
        let linkedAt = live.flatMap { key in status.peers.first { $0.publicKey == key } }?.tailscaleIPs.compactMap(IPAddress.init)
            .sorted { $0.isV4 && !$1.isV4 }.first
        if let linkedAt {
            target = linkedAt.description
        } else if !namedOnline, let first = ranked.first(where: { $0.address != target }) {
            target = first.address
        } else if let named, !named.online {
            let base = named.hostName.lowercased().hasSuffix("-kore") ? String(named.hostName.dropLast(5)) : named.hostName
            let sibling = status.peers.first { peer in
                peer.online && peer.publicKey != named.publicKey && peer.userID == named.userID && (peer.tags.isEmpty == named.tags.isEmpty)
                    && [base.lowercased(), base.lowercased() + "-kore"].contains(peer.hostName.lowercased())
            }
            if let address = sibling?.tailscaleIPs.compactMap(IPAddress.init).sorted(by: { $0.isV4 && !$1.isV4 }).first { target = address.description }
        }
        var options: [String] = []
        let moved = target != (ip?.description ?? host)
        if moved || own != nil {
            options += ["-o", "HostName=\(target)"]
            if !keyAlias { options += ["-o", "HostKeyAlias=\(host)"] }
        }
        if let own {
            // Double quotes: sh reads them as ssh runs it, and rsync's `-e` keeps them inside the
            // single quotes it takes a word with spaces in (`SyncBox.sshCommand`).
            options += ["-o", "ProxyCommand=\"\(own.helper)\" nc -socket \"\(own.socket)\" %h %p"]
        }
        return options
    }

    /// A MagicDNS name ("mybox.tail1234.ts.net") naming a node by its host name.
    static func sameName(_ hostName: String, _ dns: String) -> Bool {
        let first = dns.split(separator: ".").first.map { $0.lowercased() } ?? ""
        return !first.isEmpty && first == hostName.lowercased()
    }

    /// `ssh -G <alias>`'s host, and whether a jump host or a host key alias is set.
    private static func resolve(_ alias: String) -> (host: String, jump: Bool, keyAlias: Bool)? {
        if let kept = resolved.withLock({ $0[alias] }), Date().timeIntervalSince(kept.at) < 30 { return (kept.host, kept.jump, kept.keyAlias) }
        let address = BoxAddress(alias)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHTransport.ssh)
        process.arguments = ["-G"] + (address?.options ?? []) + ["--", address?.host ?? alias]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        var host: String?
        var jump = false
        var keyAlias = false
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "hostname": host = parts[1]
            case "proxyjump": jump = parts[1] != "none"
            case "hostkeyalias": keyAlias = parts[1] != "none"
            default: break
            }
        }
        guard let host else { return nil }
        resolved.withLock { $0[alias] = (Date(), host, jump, keyAlias) }
        return (host, jump, keyAlias)
    }
}
