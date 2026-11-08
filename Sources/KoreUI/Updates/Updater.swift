import Foundation
import KoreCore
import Observation

/// Kore's own updates: the repo's latest release, asked for when a window opens and at no other
/// time. Only a version newer than this one shows, as the cue on the new-tab picker (`UpdateCue`);
/// one click builds and installs it with install.sh, which starts Kore again on it.
@MainActor @Observable
package final class Updater {
    package static let shared = Updater()
    nonisolated package static let repo = "SoumilB7/kore"

    package enum State: Equatable {
        case current
        /// A newer release, by version ("0.3.0").
        case available(String)
        case installing(String, since: Date)
        /// The version it was after, and the installer's last words.
        case failed(String, String)
    }

    package private(set) var state = State.current
    /// A storyline's installer, in place of the real one: what went wrong.
    @ObservationIgnored package var storyInstaller: (@Sendable () async -> String)?
    @ObservationIgnored private var checking = false

    /// This app's version.
    package var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// A window opened. Only an installed app asks: not a storyline, not a binary run from .build.
    package func windowOpened() {
        guard !checking, Bundle.main.bundleURL.pathExtension == "app", StorylineSeams.backend == nil else { return }
        checking = true
        Task {
            defer { checking = false }
            await check()
        }
    }

    /// Asks GitHub for the latest release. Quiet when offline: what it knew stays.
    private func check() async {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let latest = Self.tag(data)
        else { return }
        if case .installing = state { return }
        state = Self.newer(latest, than: version) ? .available(latest) : .current
    }

    /// A release's version from GitHub's answer: its tag without the "v".
    nonisolated static func tag(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, !tag.isEmpty else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// "0.10.0" is newer than "0.9.3"; a missing part counts as 0.
    nonisolated static func newer(_ a: String, than b: String) -> Bool { ReleaseManifest.newer(a, than: b) }

    /// A storyline's release.
    package func storySet(_ state: State) { self.state = state }

    /// Builds and installs the latest with the same line a first install is. It runs apart from
    /// Kore, which it quits when the new app is built (asking first if chats are working), and
    /// opens the new one; it comes back here only if it stopped short.
    package func install() {
        let version: String
        switch state {
        case .available(let latest), .failed(let latest, _): version = latest
        case .current, .installing: return
        }
        state = .installing(version, since: Date())
        let story = storyInstaller
        Task.detached {
            let failure = if let story { await story() } else { Self.runInstaller(version) }
            await MainActor.run { self.state = .failed(version, failure) }
        }
    }

    /// The installer's line, pinned to the release found: install.sh checks that release's
    /// signature and refuses one older than this app. Only a plain version is passed on.
    nonisolated static func installLine(_ version: String) -> String {
        let pinned = !version.isEmpty && version.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") } ? " -s -- v\(version)" : ""
        return "set -o pipefail; curl -fsSL https://raw.githubusercontent.com/\(repo)/main/install.sh | bash" + pinned
    }

    /// Runs the installer to its end, which a successful one doesn't let this process see. What
    /// went wrong, in its words.
    nonisolated private static func runInstaller(_ version: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", installLine(version)]
        // To a file, not a pipe: it has to outlive Kore, and a build says more than a pipe holds.
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("kore-update-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        guard let handle = try? FileHandle(forWritingTo: log) else { return "couldn't start the update" }
        process.standardOutput = handle
        process.standardError = handle
        do { try process.run() } catch { return "couldn't start the update" }
        process.waitUntilExit()
        try? handle.close()
        let said = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let last = said.split(whereSeparator: \.isNewline).last { $0.hasPrefix("✗ ") }
        return last.map { String($0.dropFirst(2)) } ?? "the update didn't finish"
    }
}
