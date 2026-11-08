import Foundation
import KoreCore
import LinkProtocol
import Observation

/// "Keep boxes updated" (phase 19), on by default: a box on an older kore-host than the latest
/// release this Mac found is asked to update itself (`host.update`) once no chat works there. The
/// box downloads and checks the release, swaps itself in and restarts; links come back by
/// themselves. A box that can't reach GitHub says `offline`: this Mac downloads the release,
/// checks it, and the box pulls it over the link (`host.update.get`). A box as new or newer (a
/// dev build) is never asked. A box hears the setting (`host.keep`) at each link-up, for its
/// `kore-host status`. The SSH Update (BoxSetup with a BoxHostBuild) stays the dev Mac's way.
@MainActor @Observable
package final class BoxUpdates {
    package static let shared = BoxUpdates()
    package static let keepKey = "keepBoxesUpdated"
    /// A box asked for a version isn't asked again for it sooner than this.
    nonisolated package static let retryAfter: TimeInterval = 30 * 60
    /// An update that hasn't come back by then (a box that never restarted) stops showing.
    nonisolated package static let workingFor: TimeInterval = 10 * 60
    /// "updated to 0.3.1" stays on the row this long.
    nonisolated package static let shownFor: Duration = .seconds(5)

    let defaults: UserDefaults
    /// The latest release this Mac found (Updater's check); nil until one was found. Linked
    /// boxes are considered again when it changes.
    package var latest: String? {
        didSet { if latest != oldValue { considerAll() } }
    }
    /// Each box's update as Devices shows it, by alias.
    package private(set) var work: [String: Work] = [:]
    @ObservationIgnored package var now: () -> Date = Date.init
    @ObservationIgnored package var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// What this Mac is called on a box ("Soumil's MacBook Air").
    @ObservationIgnored package var macName: () -> String = { BoxUpdates.computerName() }
    /// Downloads a release file to a local file (tests: a fake).
    @ObservationIgnored package var download: @Sendable (URL, URL) async throws -> Void = BoxUpdates.fetch
    /// A release's folder online, by version (KORE_RELEASE_URL for a rehearsal's).
    @ObservationIgnored package var releaseBase: (String) -> String = { version in
        ProcessInfo.processInfo.environment["KORE_RELEASE_URL"] ?? "https://github.com/SoumilB7/kore/releases/download/v\(version)"
    }
    /// The release key the files must be signed with.
    @ObservationIgnored package var releaseKey = KoreReleaseKey.base64
    /// Where this Mac keeps a release for boxes that can't reach GitHub, a folder per version.
    @ObservationIgnored package var folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Kore", isDirectory: true).appendingPathComponent("box-release", isDirectory: true)
    /// Each box's last ask: the version and when.
    @ObservationIgnored private(set) var asked: [String: (version: String, at: Date)] = [:]
    /// The boxes linked now, as each link sees them.
    @ObservationIgnored private var links: [String: @MainActor () -> Box?] = [:]
    /// Updates this Mac sends the files for, by id: the folder the box pulls them from.
    @ObservationIgnored private(set) var serving: [String: (folder: URL, names: Set<String>)] = [:]

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// A box's update: the version it's going to, since when, and when it came back on it.
    package struct Work: Equatable, Sendable {
        package var to: String
        package var since: Date
        package var done: Date?
    }

    /// The setting, kept in this Mac's defaults. Linked boxes hear it at once.
    package var keep: Bool {
        get {
            access(keyPath: \.keep)
            return defaults.object(forKey: Self.keepKey) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.keep) { defaults.set(newValue, forKey: Self.keepKey) }
            for box in linked() where box.caps.contains(UpdateWire.cap) { _ = box.send(StreamWire.encode(UpdateWire.Keep(on: newValue, by: macName()))) }
            considerAll()
        }
    }

    /// What a link to a box knows: its alias, its kore-host version and caps, and whether a chat
    /// works there. `send` posts one message on the link; `fresh` reads the link again later.
    package struct Box {
        package var alias: String
        package var version: String
        package var caps: [String]
        package var working: Bool
        package var send: @MainActor (Data) -> Bool
        package var fresh: (@MainActor () -> Box?)?

        package init(
            alias: String, version: String, caps: [String], working: Bool, send: @escaping @MainActor (Data) -> Bool, fresh: (@MainActor () -> Box?)? = nil
        ) {
            self.alias = alias
            self.version = version
            self.caps = caps
            self.working = working
            self.send = send
            self.fresh = fresh
        }
    }

    /// A full link came up: the box hears the setting, then is asked to update when it should.
    package func linkedUp(_ box: Box) {
        if let fresh = box.fresh { links[box.alias] = fresh }
        settle(box)
        guard box.caps.contains(UpdateWire.cap) else { return }
        _ = box.send(StreamWire.encode(UpdateWire.Keep(on: keep, by: macName())))
        consider(box)
    }

    /// The box's chats changed (a turn ended): asked when it should be.
    package func consider(_ box: Box) {
        guard let version = due(box) else { return }
        guard box.send(StreamWire.encode(UpdateWire.Update(id: "upd-\(UUID().uuidString.prefix(8))", version: version, by: macName()))) else { return }
        asked[box.alias] = (version, now())
        HostLog.note(box.alias, "update asked", "\(box.version) → \(version)")
    }

    /// The version to ask `box` for now, or nil: the setting is on, the box takes `host.update`,
    /// is older than the latest release (a dev build as new or newer never is), no chat works
    /// there, no update runs there, and it wasn't just asked.
    package func due(_ box: Box) -> String? {
        guard keep, let latest, box.caps.contains(UpdateWire.cap), !box.working else { return nil }
        guard ReleaseManifest.newer(latest, than: box.version) else { return nil }
        if let running = work[box.alias], running.done == nil { return nil }
        if let last = asked[box.alias], last.version == latest, now().timeIntervalSince(last.at) < Self.retryAfter { return nil }
        return latest
    }

    /// The box's answer: `started` shows on its row; `offline` gets the files from this Mac; busy
    /// waits for the next idle chat, the rest for the retry.
    package func answered(_ alias: String, _ result: UpdateWire.Result) {
        HostLog.note(alias, "update \(result.outcome.rawValue)", result.line)
        switch result.outcome {
        case .started:
            // Twice when the files come from this Mac: the row runs from the first.
            if let to = asked[alias]?.version { work[alias] = Work(to: to, since: work[alias].flatMap { $0.done == nil ? $0.since : nil } ?? now()) }
        case .offline:
            guard let to = asked[alias]?.version, let asset = result.asset else { return work[alias] = nil }
            Task { await sendFiles(alias, version: to, asset: asset) }
        case .busy:
            asked[alias] = nil
            work[alias] = nil
        case .current, .failed, .unknown:
            work[alias] = nil
        }
    }

    // MARK: The Mac's copy

    /// The release `version` here (downloaded once, checked against the release key), then the
    /// box asked again to pull it from this Mac.
    func sendFiles(_ alias: String, version: String, asset: String) async {
        guard Self.isAsset(asset) else { return work[alias] = nil }
        let here = folder.appendingPathComponent(version, isDirectory: true)
        let names = ["SHA256SUMS", "SHA256SUMS.sig", asset]
        // One release kept: an older one's folder goes.
        for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where old.lastPathComponent != version {
            try? FileManager.default.removeItem(at: old)
        }
        do {
            try FileManager.default.createDirectory(at: here, withIntermediateDirectories: true)
            for name in names where !FileManager.default.fileExists(atPath: here.appendingPathComponent(name).path) {
                guard let url = URL(string: releaseBase(version) + "/" + name) else { throw ReleaseError.missing(name) }
                let part = here.appendingPathComponent(name + ".part")
                try? FileManager.default.removeItem(at: part)
                try await download(url, part)
                try FileManager.default.moveItem(at: part, to: here.appendingPathComponent(name))
            }
            let manifest = try ReleaseManifest.verified(
                sums: Data(contentsOf: here.appendingPathComponent("SHA256SUMS")), signature: Data(contentsOf: here.appendingPathComponent("SHA256SUMS.sig")),
                key: releaseKey)
            guard manifest.version == version else { throw ReleaseError.malformed("SHA256SUMS is \(manifest.version), not \(version)") }
            try manifest.check(here.appendingPathComponent(asset), as: asset)
        } catch {
            // A copy that doesn't check out is never kept, nor sent.
            try? FileManager.default.removeItem(at: here)
            HostLog.note(alias, "update copy failed", "\(error)")
            work[alias] = nil
            return
        }
        guard let box = links[alias]?(), !box.working else { return work[alias] = nil }
        let id = "upd-\(UUID().uuidString.prefix(8))"
        serving[id] = (here, Set(names))
        guard box.send(StreamWire.encode(UpdateWire.Update(id: id, version: version, by: macName(), from: UpdateWire.fromMac))) else {
            serving[id] = nil
            return work[alias] = nil
        }
        HostLog.note(alias, "update sent from this Mac", version)
    }

    /// `host.update.get`: the piece asked for, or `total` 0 when this Mac has no such file for it.
    package func piece(_ get: UpdateWire.Get) -> UpdateWire.Piece {
        let none = UpdateWire.Piece(id: get.id, name: get.name, offset: get.offset, total: 0, data: "")
        guard let served = serving[get.id], served.names.contains(get.name) else { return none }
        let url = served.folder.appendingPathComponent(get.name)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0,
              get.offset >= 0, get.offset < size, let handle = try? FileHandle(forReadingFrom: url)
        else { return none }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(get.offset))) != nil, let data = try? handle.read(upToCount: min(UpdateWire.pieceSize, size - get.offset)) else { return none }
        return UpdateWire.Piece(id: get.id, name: get.name, offset: get.offset, total: size, data: data.base64EncodedString())
    }

    /// "kore-host-linux-x86_64.xz": the only kind of name a box may ask this Mac to fetch.
    static func isAsset(_ name: String) -> Bool {
        name.hasPrefix("kore-host-") && name.hasSuffix(".xz") && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    // MARK: Rows

    /// A link up again: a box on the version it went to is done (shown a moment); one that
    /// didn't get there in time stops showing.
    private func settle(_ box: Box) {
        guard let running = work[box.alias], running.done == nil else { return }
        if !ReleaseManifest.newer(running.to, than: box.version) {
            let at = now()
            work[box.alias]?.done = at
            for (id, served) in serving where served.folder.lastPathComponent == running.to { serving[id] = nil }
            HostLog.note(box.alias, "updated", box.version)
            Task { [weak self, sleep, alias = box.alias] in
                await sleep(Self.shownFor)
                guard let self, self.work[alias]?.done == at else { return }
                self.work[alias] = nil
            }
        } else if now().timeIntervalSince(running.since) > Self.workingFor {
            work[box.alias] = nil
        }
    }

    private func linked() -> [Box] {
        var boxes: [Box] = []
        for (alias, fresh) in links {
            if let box = fresh() { boxes.append(box) } else { links[alias] = nil }
        }
        return boxes
    }

    private func considerAll() {
        for box in linked() { consider(box) }
    }

    /// One release file to `to`.
    @Sendable nonisolated static func fetch(_ url: URL, _ to: URL) async throws {
        let (file, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw ReleaseError.missing(url.lastPathComponent)
        }
        try FileManager.default.moveItem(at: file, to: to)
    }

    /// This Mac's name as people know it.
    nonisolated package static func computerName() -> String {
        #if os(macOS)
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }
}

extension BoxUpdates.Box {
    /// A linked box as its connection knows it; nil before its welcome.
    @MainActor
    package init?(_ connection: HostConnection) {
        guard let version = connection.hostVersion else { return nil }
        self.init(
            alias: connection.alias, version: version, caps: connection.caps,
            working: connection.chats.values.contains { $0.running || $0.state == .working },
            send: { [weak connection] in connection?.post($0) ?? false },
            fresh: { [weak connection] in connection.flatMap { BoxUpdates.Box($0) } })
    }
}
