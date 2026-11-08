import Foundation
import KoreTrust
import LinkProtocol
import Tailnet

/// `kore-host status`: what's installed and running on this box, a line each. Reads only.
package enum HostStatus {
    package static func lines(
        paths: HostPaths, home: String = HostPaths.home().path, environment: [String: String] = ProcessInfo.processInfo.environment,
        run: HostRunner = HostService.system, tailnet: () -> (any Tailnet)? = { TailnetLocal() },
        portHolder: () -> UInt32? = { PortHolder.uid(port: HostNet.port) }
    ) -> [String] {
        var lines = ["kore-host \(HostVersion.string) (link \(HostVersion.link))"]
        func row(_ name: String, _ value: String) { lines.append(name.padding(toLength: 9, withPad: " ", startingAt: 0) + value) }

        if let problem = paths.runtimeProblem {
            row("daemon", "unknown: \(problem)")
        } else if HostLock.held(paths.lock) {
            let pid = (try? String(contentsOf: paths.pid, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            row("daemon", "running" + (pid.map { " (pid \($0))" } ?? ""))
        } else {
            row("daemon", "not running")
        }
        #if os(Linux)
        let active = run(["systemctl", "--user", "is-active", HostService.unitName])
        if active.status != 127 {
            let enabled = run(["systemctl", "--user", "is-enabled", HostService.unitName])
            // One word each, unless systemctl can't reach the user's manager (no session here).
            let said = [active.lastLine, enabled.lastLine].filter { !$0.isEmpty }
            row("service", said.allSatisfy { !$0.contains(" ") } ? said.joined(separator: ", ") : "unknown: " + (said.first ?? ""))
            let linger = run(["loginctl", "show-user", HostService.user(), "--property=Linger", "--value"])
            if linger.ok { row("linger", linger.lastLine) }
        }
        #endif

        lines += net(paths: paths, on: HostConfig.load(paths.config, home: home).netOn, tailnet: tailnet, portHolder: portHolder)

        // Legacy grants: the SSH route's, kept until their Mac has upgraded (then 30 days).
        let grants = GrantStore(paths.grants).all()
        if !grants.isEmpty {
            let day = DateFormatter()
            day.dateFormat = "yyyy-MM-dd"
            day.timeZone = TimeZone(identifier: "UTC")
            row("grants", grants.map { grant in
                var said = grant.control.rawValue
                if let device = grant.device { said += ", upgraded to " + DeviceRecord.code(device) }
                if let expires = grant.expires { said += ", expires " + day.string(from: Date(timeIntervalSince1970: Double(expires))) }
                return "\(grant.name) (\(said))"
            }.joined(separator: ", "))
        }

        let config = HostConfig.load(paths.config, home: home)
        if let why = config.unreadable { row("config", "\(paths.config.path) couldn't be read: \(why)") }
        if config.folders.isEmpty { row("folders", "none") }
        for (i, folder) in config.folders.enumerated() {
            row(i == 0 ? "folders" : "", folder + (HostConfig.missing(folder) ? " (missing)" : ""))
        }

        for cli in ["claude", "codex"] { row(cli, find(cli, home: home, environment: environment) ?? "not found") }
        return lines
    }

    /// The CLI's path, on this shell's PATH or the service's.
    package static func find(_ name: String, home: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let service = HostService.searchPath.replacingOccurrences(of: "%h", with: home)
        let dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + service.split(separator: ":").map(String.init)
        for dir in dirs where !dir.isEmpty {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// KoreNet's rows: this box's device id, the tailnet, who holds the port, its devices and
    /// those waiting.
    static func net(paths: HostPaths, on: Bool, tailnet: () -> (any Tailnet)?, portHolder: () -> UInt32?) -> [String] {
        var lines: [String] = []
        func row(_ name: String, _ value: String) { lines.append(name.padding(toLength: 9, withPad: " ", startingAt: 0) + value) }
        row("net", on ? "on" : "off (kore-host net on)")
        if let me = BoxIdentity.load(paths) {
            row("device", "\(me.device.uuidString.lowercased()) (code \(me.code))")
        } else {
            row("device", "none yet (kore-host join)")
        }
        if on, let tailnet = tailnet() {
            do {
                let status = try tailnet.status()
                let ips = status.selfNode?.tailscaleIPs ?? []
                row("tailnet", status.backendState.rawValue + (ips.isEmpty ? "" : " · " + ips.joined(separator: ", ")))
                if status.backendState == .running {
                    if let uid = portHolder(), uid != getuid() {
                        row("port", "\(HostNet.port) held by uid \(uid)")
                    } else {
                        row("port", "\(HostNet.port)")
                    }
                }
            } catch {
                row("tailnet", "not reachable (\(error))")
            }
        }
        let store = DeviceStore(paths: paths)
        let devices = store.all()
        row("devices", devices.isEmpty ? "none" : devices.map { "\($0.name) (\($0.kind.rawValue), \(DeviceRecord.code($0.id)))" }.joined(separator: ", "))
        for (i, waiting) in store.pending().enumerated() {
            let code = waiting.code.map { " " + $0 } ?? ""
            row(i == 0 ? "pending" : "", "\(waiting.name)\(code) · \(waiting.login)" + (waiting.claim ? " · wants to own this box" : ""))
        }
        return lines
    }
}
