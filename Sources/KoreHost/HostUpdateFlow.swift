import Foundation
import KoreCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// What this box knows about releases, kept in `state/update.json`: the last check, the Mac whose
/// "Keep boxes updated" is on, and the last update a Mac made. `kore-host status` reads only this,
/// so it stays instant and offline.
package struct UpdateState: Codable, Equatable, Sendable {
    package var checked: Date?
    package var latest: String?
    package var released: Date?
    package var keptBy: String?
    package var keptAt: Date?
    package var pushed: Pushed?

    package struct Pushed: Codable, Equatable, Sendable {
        package var from: String
        package var to: String
        package var by: String
        package var at: Date

        package init(from: String, to: String, by: String, at: Date) {
            self.from = from
            self.to = to
            self.by = by
            self.at = at
        }
    }

    package init() {}

    package static func load(_ paths: HostPaths) -> UpdateState {
        guard let data = try? Data(contentsOf: paths.updateState) else { return UpdateState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(UpdateState.self, from: data)) ?? UpdateState()
    }

    package func save(_ paths: HostPaths) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(self) { try? HostPaths.privateFile(data, to: paths.updateState) }
    }

    /// A Mac that hasn't said it keeps this box current for this long no longer counts.
    package static let keptFor: TimeInterval = 14 * 86_400

    /// `kore-host status`'s rows: `update` (who keeps it current, or what's known), and `updated`
    /// while the version a Mac put here is the one running.
    package func rows(current: String, now: Date) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let by = keptBy, let at = keptAt, now.timeIntervalSince(at) < Self.keptFor {
            rows.append(("update", "kept up to date by \(by)"))
        } else if let latest, ReleaseManifest.newer(latest, than: current) {
            rows.append(("update", "\(latest) available · kore-host update"))
        } else if latest != nil {
            rows.append(("update", "latest" + (checked.map { ", checked \(Self.ago($0, now: now))" } ?? "")))
        } else {
            rows.append(("update", "not checked · kore-host update --check"))
        }
        if let pushed, pushed.to == current {
            rows.append(("updated", "to \(pushed.to) by \(pushed.by), \(Self.ago(pushed.at, now: now))"))
        }
        return rows
    }

    /// "just now", "5 min ago", "3 h ago", "yesterday", "2 days ago".
    package static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<60: return "just now"
        case ..<3600: return "\(s / 60) min ago"
        case ..<86_400: return "\(s / 3600) h ago"
        case ..<172_800: return "yesterday"
        default: return "\(s / 86_400) days ago"
        }
    }
}

extension HostUpdate {
    /// The running daemon's chats: at work, and with a CLI running. Nil when no daemon runs.
    package static func chats(_ paths: HostPaths) -> (working: Int, open: Int)? {
        guard HostLock.held(paths.lock) else { return nil }
        let said = (try? String(contentsOf: paths.chatsState, encoding: .utf8))?.split(separator: " ").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let said, said.count == 2 else { return (0, 0) }
        return (said[0], said[1])
    }

    /// The latest release's `SHA256SUMS` and its `.sig` into `folder`, kept with the server's
    /// time (when the release went up). Throws `HostUpdateError.failed` when it can't be reached.
    package func fetchManifest(into folder: URL, from base: String) throws {
        for name in ["SHA256SUMS", "SHA256SUMS.sig"] {
            let ran = run(["curl", "-fsSLR", "--retry", "2", "-o", folder.appendingPathComponent(name).path, base + "/" + name])
            guard ran.ok else { throw HostUpdateError.failed("downloading \(name)", ran.status == 127 ? "needs curl" : ran.lastLine) }
        }
    }

    /// This platform's asset into `folder`.
    package func fetchAsset(into folder: URL, from base: String) throws -> URL {
        let file = folder.appendingPathComponent(asset)
        let ran = run(["curl", "-fsSL", "--retry", "2", "-o", file.path, base + "/" + asset])
        guard ran.ok else { throw HostUpdateError.failed("downloading \(asset)", ran.status == 127 ? "needs curl" : ran.lastLine) }
        return file
    }
}

/// `kore-host update` and `update --check`, in words a person on the box follows: a terminal gets
/// a step a line (`✓ signature checks out`), a pipe gets `key: value` lines. A Mac's push
/// (`host.update`) runs the same steps under the daemon, with `by` naming the Mac; its lines go
/// to the journal.
package struct UpdateFlow {
    package var updater: HostUpdate
    package var paths: HostPaths
    /// The release folder: GitHub's latest, or `KORE_RELEASE_URL`.
    package var base: String
    /// Where downloads go; removed by the caller.
    package var scratch: URL
    package var tty: Bool
    package var say: (String) -> Void
    package var now: () -> Date = Date.init
    /// The daemon's chats (nil: it isn't running).
    package var chats: () -> (working: Int, open: Int)?
    /// Restarts the daemon on the new binary: whether it came back, and the line when it didn't.
    package var restart: () -> (running: Bool, line: String)
    /// Who signs releases, as the steps name them.
    package var signer = "SoumilB7 release key"

    package init(
        updater: HostUpdate, paths: HostPaths, base: String, scratch: URL, tty: Bool, say: @escaping (String) -> Void,
        chats: @escaping () -> (working: Int, open: Int)?, restart: @escaping () -> (running: Bool, line: String)
    ) {
        self.updater = updater
        self.paths = paths
        self.base = base
        self.scratch = scratch
        self.tty = tty
        self.say = say
        self.chats = chats
        self.restart = restart
    }

    /// Where releases come from, as a person reads it.
    var source: String {
        if base == HostUpdate.latest { return "github.com/SoumilB7/kore" }
        guard let url = URL(string: base), let host = url.host else { return base }
        return host + (url.port.map { ":\($0)" } ?? "")
    }

    // MARK: Words

    private func step(_ words: String, _ key: String, _ value: String) { say(tty ? "  ✓ " + words : "\(key): \(value)") }
    private func line(_ words: String, _ key: String, _ value: String) { say(tty ? words : "\(key): \(value)") }
    private func refuse(_ words: String) -> Int32 {
        say(tty ? "  ✗ " + words : "error: " + words)
        return 1
    }

    private func chatsWord(_ n: Int) -> String { n == 1 ? "1 chat" : "\(n) chats" }

    private func offline(_ error: Error, hint: Bool) -> Int32 {
        let why: String
        if case .failed(_, let said)? = error as? HostUpdateError { why = said } else { why = "\(error)" }
        line("can't reach \(source) (\(why)) · nothing changed", "error", "can't reach \(source): \(why)")
        if hint {
            let page = base == HostUpdate.latest ? "https://github.com/SoumilB7/kore/releases/latest" : base
            line(
                "  elsewhere, download SHA256SUMS, SHA256SUMS.sig and \(updater.asset) from \(page), copy them here, then: kore-host update --file \(updater.asset)",
                "hint", "kore-host update --file \(updater.asset) (with SHA256SUMS and SHA256SUMS.sig beside it, from \(page))")
        }
        return 1
    }

    private func refused(_ error: Error) -> Int32 {
        switch error as? ReleaseError {
        case .badSignature?, .noKey?: refuse("SHA256SUMS isn't signed by Kore's release key · nothing changed")
        case .mismatch(let name)?: refuse("\(name) doesn't match its signed hash · nothing changed")
        case .missing(let name)?: refuse("the release has no \(name) · nothing changed")
        case .malformed?: refuse("SHA256SUMS isn't a Kore release · nothing changed")
        case .wrongBinary(let said)?: refuse("the new kore-host doesn't run here (\(said.isEmpty ? "no answer" : said)) · nothing changed")
        default: refuse("\(error) · nothing changed")
        }
    }

    /// The signed manifest beside `file`, with the release's upload time when the server gave it.
    private func manifest(beside file: URL) throws -> (ReleaseManifest, released: Date?) {
        let manifest = try updater.manifest(beside: file)
        let sums = file.deletingLastPathComponent().appendingPathComponent("SHA256SUMS")
        let time = (try? FileManager.default.attributesOfItem(atPath: sums.path))?[.modificationDate] as? Date
        // A file without the server's time is as new as now: no "released" then.
        let released = time.flatMap { now().timeIntervalSince($0) > 120 ? $0 : nil }
        return (manifest, released)
    }

    private func remember(_ manifest: ReleaseManifest, released: Date?) {
        var state = UpdateState.load(paths)
        state.checked = now()
        state.latest = manifest.version
        state.released = released
        state.save(paths)
    }

    // MARK: Runs

    /// `--check`: one line, no binary downloaded.
    package func check() -> Int32 {
        let current = updater.current
        let sums = scratch.appendingPathComponent("SHA256SUMS")
        do { try updater.fetchManifest(into: scratch, from: base) } catch { return offline(error, hint: false) }
        let found: (ReleaseManifest, released: Date?)
        do { found = try self.manifest(beside: sums) } catch { return refused(error) }
        let (manifest, released) = found
        remember(manifest, released: released)
        let latest = manifest.version
        if ReleaseManifest.newer(latest, than: current) {
            line("\(latest) is out (you have \(current)) · kore-host update", "update", "\(latest) available (have \(current))")
        } else if latest == current {
            line("kore-host \(current) is the latest", "update", "latest (\(current))")
        } else {
            line("kore-host \(current) is newer than the latest release (\(latest))", "update", "newer than the latest release (\(latest))")
        }
        return 0
    }

    /// `update`: from the release (or `file`), only while no chat works unless `now`, then the
    /// restart. `by`: the Mac that asked, for the journal and `status`.
    package func update(file given: URL? = nil, now anyway: Bool = false, force: Bool = false, by: String? = nil) -> Int32 {
        let current = updater.current
        if !anyway, let working = chats()?.working, working > 0 {
            line("\(chatsWord(working)) \(working == 1 ? "is" : "are") working · run again when they finish, or --now", "error", "\(chatsWord(working)) working")
            return 1
        }

        // The signed manifest first: it says the version.
        let sumsAt: URL
        if let given {
            sumsAt = given
        } else {
            do { try updater.fetchManifest(into: scratch, from: base) } catch { return offline(error, hint: true) }
            sumsAt = scratch.appendingPathComponent("SHA256SUMS")
        }
        let found: (ReleaseManifest, released: Date?)
        do { found = try self.manifest(beside: sumsAt) } catch { return refused(error) }
        let (manifest, released) = found
        if given == nil { remember(manifest, released: released) }
        let latest = manifest.version
        let folder = sumsAt.deletingLastPathComponent()
        if !force {
            if latest == current {
                line("kore-host \(current) is the latest", "update", "latest (\(current))")
                // Kore's own tailnet missing beside it (an older Set up): the release's.
                if !FileManager.default.isExecutableFile(atPath: updater.tailnetTarget.path),
                   let said = updater.placeTailnet(manifest, folder: folder, base: given == nil ? base : nil) {
                    step(said, "tailnet", said)
                }
                return 0
            }
            if ReleaseManifest.newer(current, than: latest) {
                line("kore-host \(current) is newer than \(latest) · --force installs \(latest)", "error", "\(latest) is older than \(current)")
                return 1
            }
        }

        line("kore-host \(current) → \(latest)", "update", "\(current) → \(latest)")
        let file: URL
        if let given {
            file = given
            step("read \(given.lastPathComponent) (\(size(given)))", "file", "\(given.path) \(size(given))")
        } else {
            let when = released.map { ", released \(UpdateState.ago($0, now: now()))" } ?? ""
            step("found \(latest) (\(source)\(when))", "found", "\(latest) \(source)")
            do { file = try updater.fetchAsset(into: scratch, from: base) } catch { return offline(error, hint: true) }
            step("downloaded \(updater.asset.replacingOccurrences(of: ".xz", with: "")) (\(size(file)))", "downloaded", "\(updater.asset) \(size(file))")
        }
        do { try manifest.check(file, as: updater.asset) } catch { return refused(error) }
        step("signature checks out (\(signer))", "signature", "ok")

        // Again just before the swap: a turn may have started while it downloaded.
        switch chats() {
        case nil:
            step("kore-host isn't running, safe to swap", "chats", "none (not running)")
        case let (working, open)? where working > 0:
            guard anyway else {
                line("\(chatsWord(working)) \(working == 1 ? "is" : "are") working · run again when they finish, or --now", "error", "\(chatsWord(working)) working")
                return 1
            }
            step("--now: \(chatsWord(working)) of \(open) stop mid-turn", "chats", "\(working) working, --now")
        case let (_, open)?:
            step(open == 0 ? "no chats open, safe to restart" : "\(chatsWord(open)) idle, safe to restart", "chats", "\(open) idle")
        }

        do {
            switch try updater.apply(file, force: true) {
            case .same:
                line("kore-host \(current) is the latest", "update", "latest (\(current))")
                return 0
            case .updated: break
            }
        } catch { return refused(error) }
        // Kore's own tailnet from the same release, beside the new kore-host (before the restart:
        // the daemon starts it when it's the box's choice).
        if let said = updater.placeTailnet(manifest, folder: folder, base: given == nil ? base : nil) { step(said, "tailnet", said) }
        if let by {
            var state = UpdateState.load(paths)
            state.pushed = .init(from: current, to: latest, by: by, at: now())
            state.save(paths)
            HostJournal.note("updated", ["from": current, "to": latest, "by": by])
        }
        step("swapped, restarting… phones and Macs reconnect by themselves", "swapped", latest)
        let restarted = restart()
        if restarted.running {
            line("kore-host \(latest) is running", "running", latest)
            return 0
        }
        line(restarted.line, "restart", restarted.line)
        return 0
    }

    private func size(_ file: URL) -> String {
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int) ?? 0
        return bytes >= 1_048_576 ? "\(Int((Double(bytes) / 1_048_576).rounded())) MB" : "\(max(1, bytes / 1024)) KB"
    }
}
