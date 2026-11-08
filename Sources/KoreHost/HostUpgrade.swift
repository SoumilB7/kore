import Foundation
import KoreCore
import KoreTrust
import Tailnet
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// `kore-host upgrade`: one idempotent command that puts this box on KoreNet (phase 18 §2g,
/// U1–U3), run by the Mac over its SSH link or by a person by hand, with the same result:
///
/// - U1 kore-host as new as `--want` (the latest release, checked against its signed sums);
/// - U2 its service installed and running;
/// - U3 `net on`, Tailscale looked at, and the port's state as the daemon says it;
/// - the calling Mac's grant (`--grant`, full) made when it's missing: SSH proves the owner, as
///   Set up's `allow` does. The Mac enrolls over it after (`attach --proto 2`, U4).
///
/// Every step is a no-op when it's done already, so a second run changes nothing. It prints
/// `key: value` lines (`HostUpgrade.Report`) and exits 0 when the box is on KoreNet, 2 when a
/// person is needed (the `error:` line says which, `action:` the line to run), 1 on a failure.
package struct HostUpgrade {
    /// Installed Tailscale as this box sees it.
    package enum Tailscale: Equatable, Sendable {
        case running(node: String?)
        /// Installed, not running: stopped, or signed out (its sign-in page when one is open).
        case stopped(BackendState, login: String?)
        /// Not installed, or its LocalAPI isn't there.
        case absent
        /// Its LocalAPI refused this user.
        case denied
    }

    /// kore-host's service here.
    package enum Service: Equatable, Sendable {
        case running, stopped, missing
    }

    package var paths: HostPaths
    /// The home `~` in config.json means.
    package var home = HostPaths.home().path
    package var version = HostVersion.string
    package var link = HostVersion.link
    /// U1: the latest release in place of this binary when it's newer; what was done
    /// (`"0.2.2 → 0.2.3"`), or nil when there was nothing newer.
    package var update: () throws -> String?
    package var service: () -> Service
    package var installService: () throws -> [String]
    package var startDaemon: () -> Bool
    /// Whether the service outlives the last login (nil: no systemd to ask).
    package var linger: () -> Bool?
    package var tailscale: () -> Tailscale
    /// The running daemon reads `config.json` again (SIGHUP).
    package var reload: () -> Void
    /// The daemon's own word on the port after a reload (`net.state`), waited on briefly.
    package var listen: (_ since: Date?) -> String?
    /// Who holds the port, when it's another user.
    package var portHolder: () -> UInt32?
    package var now: () -> Date = Date.init

    package init(
        paths: HostPaths, update: @escaping () throws -> String?, service: @escaping () -> Service, installService: @escaping () throws -> [String],
        startDaemon: @escaping () -> Bool, linger: @escaping () -> Bool?, tailscale: @escaping () -> Tailscale, reload: @escaping () -> Void,
        listen: @escaping (Date?) -> String?, portHolder: @escaping () -> UInt32? = { nil }
    ) {
        self.paths = paths
        self.update = update
        self.service = service
        self.installService = installService
        self.startDaemon = startDaemon
        self.linger = linger
        self.tailscale = tailscale
        self.reload = reload
        self.listen = listen
        self.portHolder = portHolder
    }

    /// What it prints: one `key: value` per line, in order; `state` and the exit code last.
    package struct Report: Equatable, Sendable {
        package var lines: [(key: String, value: String)] = []
        package var exit: Int32 = 0
        /// U1 swapped this binary in: the new one runs the rest (`kore-host upgrade` again).
        package var updated = false

        package mutating func add(_ key: String, _ value: String) { lines.append((key, value)) }
        package func value(_ key: String) -> String? { lines.last { $0.key == key }?.value }
        package var text: [String] { lines.map { "\($0.key): \($0.value)" } }

        package static func == (a: Report, b: Report) -> Bool { a.text == b.text && a.exit == b.exit && a.updated == b.updated }
    }

    package enum Exit {
        package static let done: Int32 = 0
        package static let failed: Int32 = 1
        package static let person: Int32 = 2
    }

    /// The line a person runs to start installed Tailscale.
    package static let sudoLine = "sudo tailscale up"
    /// The line that installs Tailscale.
    package static let installLine = "curl -fsSL https://tailscale.com/install.sh | sh"

    /// Runs U1–U3 (and the grant), each only when it isn't done yet.
    package func run(want: String?, grant: String?) -> Report {
        var report = Report()
        var failure: String?
        var person: (error: String, action: String?)?
        report.add("version", version)
        report.add("link", link)

        // U1: as new as the Mac, when the release is.
        if let want, ReleaseManifest.newer(want, than: version) {
            do {
                if let swapped = try update() {
                    report.add("update", swapped)
                    report.updated = true
                    return report
                }
                report.add("update", "no newer release")
            } catch {
                report.add("update", "failed \(error)")
                failure = "update failed"
            }
        } else {
            report.add("update", "current")
        }

        // U2: the service, installed once and running.
        switch service() {
        case .running:
            report.add("service", "running")
        case .stopped:
            if startDaemon() {
                report.add("service", "started")
            } else {
                report.add("service", "failed to start")
                failure = failure ?? "service didn't start"
            }
        case .missing:
            do {
                _ = try installService()
                report.add("service", "installed")
            } catch {
                report.add("service", "failed \(error)")
                failure = failure ?? "service didn't install"
            }
        }
        if let linger = linger() { report.add("linger", linger ? "on" : "off") }

        // Who this box is, and the calling Mac's grant.
        let identity: BoxIdentity
        do {
            identity = try BoxIdentity.loadOrCreate(paths)
        } catch {
            report.add("error", "identity: \(error)")
            report.add("state", "failed")
            report.exit = Exit.failed
            return report
        }
        report.add("device", identity.device.uuidString.lowercased())
        report.add("code", identity.code)
        if let grant {
            let grants = GrantStore(paths.grants)
            // A grant whose Mac the box has forgotten (removed, or the book set up again) is used:
            // its Mac's proof is turned away. It counts as missing, and is made afresh.
            let held = grants.load(grant)
            let forgotten = held?.device.map { device in !DeviceStore(paths: paths).all().contains { $0.id == device } } ?? false
            if let held, !forgotten {
                report.add("mac", held.device == nil ? "allowed" : "enrolled")
            } else {
                do {
                    try grants.allow(grant, control: .full, socket: paths.socket)
                    HostJournal.audit("allow", ["grant": grant, "how": forgotten ? "upgrade, its Mac forgotten" : "upgrade"])
                    report.add("mac", "allowed")
                } catch {
                    report.add("mac", "failed \(error)")
                    failure = failure ?? "grant: \(error)"
                }
            }
        }

        // U3: on KoreNet, and how Tailscale is.
        var config = HostConfig.load(paths.config, home: home)
        let wasOn = config.netOn
        if !wasOn {
            config.net = true
            do {
                try config.save(paths.config)
                HostJournal.audit("net", ["on": "1", "how": "upgrade"])
            } catch {
                report.add("net", "failed \(error)")
                report.add("error", "config: \(error)")
                report.add("state", "failed")
                report.exit = Exit.failed
                return report
            }
        }
        // An unclaimed box takes its owner Mac's claim for the next 10 minutes (as `join`).
        if !DeviceStore(paths: paths).claimed { try? NetJoin.mark(paths, at: now()) }
        report.add("net", "on")
        let seen = tailscale()
        switch seen {
        case .running(let node):
            report.add("tailscale", "running")
            if let node { report.add("node", node) }
        case .stopped(let state, let login):
            report.add("tailscale", state == .needsLogin ? "signed out" : "stopped")
            if let login { report.add("login", login) }
            person = ("tailscale " + (state == .needsLogin ? "signed out" : "stopped"), Self.sudoLine)
        case .absent:
            report.add("tailscale", "absent")
            person = ("tailscale absent", Self.installLine)
        case .denied:
            report.add("tailscale", "no access")
            person = ("no sudo", Self.sudoLine)
        }
        // The daemon looks again: a box turned on now binds; one on already but not bound (its
        // Tailscale came up meanwhile) binds too. A bound one keeps its sockets.
        let since = stateTime()
        let said: String?
        if !wasOn || !listening() {
            reload()
            said = listen(since)
        } else {
            said = currentState()
        }
        if let said { report.add("listen", said) }
        if case .running = seen, let said, !said.hasPrefix("listening") {
            if said.contains("in use") {
                let uid = portHolder()
                person = person ?? ("port held" + (uid.map { " by uid \($0)" } ?? ""), nil)
            } else if failure == nil, person == nil {
                person = ("not listening", nil)
            }
        }

        if let person {
            report.add("error", person.error)
            if let action = person.action { report.add("action", action) }
            report.add("state", "needs you")
            report.exit = Exit.person
        } else if let failure {
            report.add("error", failure)
            report.add("state", "failed")
            report.exit = Exit.failed
        } else {
            report.add("state", "done")
            report.exit = Exit.done
        }
        return report
    }

    private func currentState() -> String? {
        (try? String(contentsOf: paths.netState, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func listening() -> Bool { currentState()?.hasPrefix("listening") == true }

    private func stateTime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: paths.netState.path))?[.modificationDate] as? Date
    }
}

extension HostUpgrade {
    /// This box's own: the release download, systemd or launchd, LocalAPI, SIGHUP, `net.state`.
    package static func standard(paths: HostPaths, home: URL) -> HostUpgrade {
        var upgrade = HostUpgrade(
            paths: paths,
            update: {
                let updater = HostUpdate(target: URL(fileURLWithPath: HostService.executable()))
                let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kore-host-upgrade-\(getpid())")
                defer { try? FileManager.default.removeItem(at: scratch) }
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                let file = try updater.download(into: scratch)
                switch try updater.apply(file, force: false) {
                case .same: return nil
                case .updated(let from, let to):
                    _ = HostUpdate.restart(paths: paths, home: home)
                    return "\(from) → \(to)"
                }
            },
            service: {
                let installed = HostService.installed(paths) != nil || FileManager.default.fileExists(atPath: HostService.unitFile(home: home).path)
                guard installed else { return .missing }
                return HostLock.held(paths.lock) ? .running : .stopped
            },
            installService: {
                try HostService.install(HostService.kind(), executable: HostService.executable(), home: home, user: HostService.user(), paths: paths)
            },
            startDaemon: {
                HostService.start(HostService.installed(paths), executable: HostService.executable(), home: home, paths: paths)
                    && HostService.waitForDaemon(paths)
            },
            linger: {
                #if os(Linux)
                let said = HostService.system(["loginctl", "show-user", HostService.user(), "--property=Linger", "--value"])
                return said.ok ? said.lastLine == "yes" : nil
                #else
                return nil
                #endif
            },
            tailscale: {
                do {
                    let status = try TailnetLocal().status()
                    if status.backendState == .running { return .running(node: status.selfNode?.publicKey) }
                    return .stopped(status.backendState, login: status.authURL.flatMap { $0.isEmpty ? nil : $0 })
                } catch TailnetError.unauthorized {
                    return .denied
                } catch {
                    return .absent
                }
            },
            reload: {
                guard HostLock.held(paths.lock), let text = try? String(contentsOf: paths.pid, encoding: .utf8),
                      let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1
                else { return }
                kill(pid, SIGHUP)
            },
            listen: { since in waitForState(paths, since: since, seconds: 5) },
            portHolder: { PortHolder.uid(port: HostNet.port).flatMap { $0 == getuid() ? nil : $0 } })
        upgrade.home = home.path
        return upgrade
    }

    /// `net.state` once the daemon wrote it after `since` (it does once its look at Tailscale is
    /// applied), up to `seconds`; what's there then otherwise. One-shot: the command ends after.
    static func waitForState(_ paths: HostPaths, since: Date?, seconds: Double) -> String? {
        let end = Date().addingTimeInterval(seconds)
        func read() -> (Date?, String?) {
            let at = (try? FileManager.default.attributesOfItem(atPath: paths.netState.path))?[.modificationDate] as? Date
            let text = (try? String(contentsOf: paths.netState, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (at, text)
        }
        while Date() < end {
            let (at, text) = read()
            if let at, text?.isEmpty == false, since.map({ at > $0 }) ?? true { return text }
            usleep(100_000)
        }
        return read().1
    }
}
