import Foundation

/// Kore's own folders on this Mac, decided here and nowhere else: every path into Application
/// Support, Logs or Caches goes through `support`, `logs` and `caches`.
///
/// The owner's Kore, whose settings are the `dev.kore.Kore` defaults domain (the installed
/// Kore.app), keeps `~/Library/Application Support/Kore`, `~/Library/Logs/Kore` and
/// `~/Library/Caches/Kore`; so does `kore-host` on a box, as it always has. Kore Dev (a dev
/// build: `scripts/build-app.sh --dev`'s `dev.kore.KoreDev`, or the `Kore` binary run as built)
/// keeps `Kore Dev` beside them, with its own agent socket, link, KoreNet identity and logs in it.
/// Every other process keeps its own, so a renamed dev binary, KoreBench or a storyline host never
/// reads or writes the owner's: `Kore-<domain>` beside them, a test process's scratch folder, or
/// the folder a host `place`s (a storyline run's).
/// A process that isn't the owner's Kore and would resolve to the owner's folders stops at once.
package enum KoreFolders {
    package struct Places: Equatable, Sendable {
        package var support: URL
        package var logs: URL
        package var caches: URL

        package init(support: URL, logs: URL, caches: URL) {
            self.support = support
            self.logs = logs
            self.caches = caches
        }

        /// Support, logs and caches as three folders under `base`.
        package init(under base: URL) {
            self.init(
                support: base.appendingPathComponent("support", isDirectory: true),
                logs: base.appendingPathComponent("logs", isDirectory: true),
                caches: base.appendingPathComponent("caches", isDirectory: true))
        }

        func touches(_ other: Places) -> Bool {
            let mine = [support, logs, caches].map(\.standardizedFileURL.path)
            return [other.support, other.logs, other.caches].map(\.standardizedFileURL.path).contains { theirs in
                mine.contains { $0 == theirs || $0.hasPrefix(theirs + "/") }
            }
        }
    }

    /// The defaults domains of the owner's Kore, and kore-host's on a box.
    package static let ownerDomains: Set<String> = ["dev.kore.Kore", "kore-host"]

    /// Kore Dev's bundle identifier and name (`scripts/build-app.sh --dev`): a dev build never
    /// shares the owner's settings, folders, keys or sockets, and macOS (Battery, Activity
    /// Monitor) shows it apart from the owner's Kore.
    package static let devBundleID = "dev.kore.KoreDev"
    package static let devName = "Kore Dev"

    /// Kore Dev's defaults domains: its app's, and the `Kore` binary run as built.
    package static let devDomains: Set<String> = [devBundleID, "Kore", devName]

    /// This process's defaults domain (`UserDefaults.standard`'s): its bundle's identifier, else
    /// its executable's name.
    package static let domain: String = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName

    /// Whether this process is the owner's Kore (and so keeps the owner's folders).
    package static var isOwner: Bool { isOwner(domain: domain, testing: KoreLog.isTestProcess) }

    /// Whether this process is Kore Dev.
    package static var isDev: Bool { !KoreLog.isTestProcess && devDomains.contains(domain) }

    package static func isOwner(domain: String, testing: Bool) -> Bool { !testing && ownerDomains.contains(domain) }

    /// The folders the others go in: Application Support, Logs and Caches.
    package struct Bases: Equatable, Sendable {
        package var support: URL
        package var logs: URL
        package var caches: URL

        package init(support: URL, logs: URL, caches: URL) {
            self.support = support
            self.logs = logs
            self.caches = caches
        }

        /// A Mac's, under `home`.
        package init(home: URL) {
            let library = home.appendingPathComponent("Library", isDirectory: true)
            self.init(
                support: library.appendingPathComponent("Application Support", isDirectory: true),
                logs: library.appendingPathComponent("Logs", isDirectory: true),
                caches: library.appendingPathComponent("Caches", isDirectory: true))
        }

        /// This user's (`~/.local/share` and `~/.cache` on Linux).
        package static let system: Bases = {
            let files = FileManager.default
            let home = files.homeDirectoryForCurrentUser
            let mac = Bases(home: home)
            return Bases(
                support: files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? mac.support,
                logs: mac.logs,
                caches: files.urls(for: .cachesDirectory, in: .userDomainMask).first ?? mac.caches)
        }()
    }

    /// The owner's folders.
    package static func owner(_ bases: Bases = .system) -> Places { named("Kore", bases) }

    /// Where a process with this domain keeps its folders: the owner's, Kore Dev's, `Kore-<domain>`,
    /// or (a test process) a scratch folder of its own under `scratch`.
    package static func places(domain: String, testing: Bool, bases: Bases, scratch: URL, pid: Int32 = getpid()) -> Places {
        if testing { return Places(under: scratch.appendingPathComponent("kore-data-\(pid)", isDirectory: true)) }
        if ownerDomains.contains(domain) { return owner(bases) }
        if devDomains.contains(domain) { return named(devName, bases) }
        let safe = String(domain.map { $0 == "/" || $0 == ":" ? "-" : $0 })
        return named("Kore-" + (safe.isEmpty ? "unnamed" : safe), bases)
    }

    private static func named(_ name: String, _ bases: Bases) -> Places {
        Places(
            support: bases.support.appendingPathComponent(name, isDirectory: true),
            logs: bases.logs.appendingPathComponent(name, isDirectory: true),
            caches: bases.caches.appendingPathComponent(name, isDirectory: true))
    }

    /// This process's, unless a host has placed others.
    package static let standard: Places = {
        let places = Self.places(domain: domain, testing: KoreLog.isTestProcess, bases: .system, scratch: FileManager.default.temporaryDirectory)
        guard checked(places) else { fatalError(refusal(places)) }
        return places
    }()

    private static let placed = HostSetting<Places?>(nil)

    /// A host's own folders (a storyline run's), set before anything reads them. It stops the
    /// process when they are the owner's.
    package static func place(_ places: Places) {
        guard checked(places) else { fatalError(refusal(places)) }
        placed.value = places
    }

    package static var current: Places { placed.value ?? standard }

    /// `~/Library/Application Support/Kore` in the owner's Kore.
    package static var support: URL { current.support }
    /// `~/Library/Logs/Kore` in the owner's Kore.
    package static var logs: URL { current.logs }
    /// `~/Library/Caches/Kore` in the owner's Kore.
    package static var caches: URL { current.caches }

    /// The owner's Kore may use any folders; any other process none of the owner's.
    package static func allowed(_ places: Places, domain: String, testing: Bool, bases: Bases = .system) -> Bool {
        isOwner(domain: domain, testing: testing) || !places.touches(owner(bases))
    }

    private static func checked(_ places: Places) -> Bool { allowed(places, domain: domain, testing: KoreLog.isTestProcess) }

    private static func refusal(_ places: Places) -> String {
        "KoreFolders: \(domain) (not the owner's Kore) resolved to the owner's folder \(places.support.path); refusing to touch it"
    }
}
