import Foundation
import LinkProtocol

/// `kore-host status`: what's installed and running on this box, a line each. Reads only.
package enum HostStatus {
    package static func lines(
        paths: HostPaths, home: String = HostPaths.home().path, environment: [String: String] = ProcessInfo.processInfo.environment,
        run: HostRunner = HostService.system
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

        let grants = GrantStore(paths.grants).all()
        row("grants", grants.isEmpty ? "none (kore-host allow <name> --control full)" : grants.map { "\($0.name) (\($0.control.rawValue))" }.joined(separator: ", "))

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
}
