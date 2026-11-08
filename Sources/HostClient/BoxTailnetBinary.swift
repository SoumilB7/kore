import Foundation
import KoreCore
import Tailnet

/// `kore-tailnet` for a box's platform (`linux-x86_64`, `linux-aarch64`, `macos-arm64`), which
/// Set up and Update put beside kore-host: the box runs it as Kore's own tailnet when it has no
/// installed Tailscale it can use. In order: a development folder named by the `koreHostBinary`
/// default holding `kore-tailnet-<platform>[.xz]`; for a Mac box, Kore.app's own helper; the
/// copy this Kore kept before; a checkout's `build/release` (scripts/build-tailnet.sh); else this
/// Kore's own release's (`v<version>`; the latest only when that one has no kore-tailnet), taken
/// only when its `SHA256SUMS.sig` verifies with Kore's release key and the file matches its hash
/// there. Kept for the next box only under its own version's name: a newer release's never sits
/// under an older label. Nil when there's none: the box then offers Tailscale's lines.
package enum BoxTailnetBinary {
    /// The release file for a platform: Linux's are xz-compressed.
    package static func asset(_ platform: String) -> String {
        "kore-tailnet-" + platform + (platform.hasPrefix("linux-") ? ".xz" : "")
    }

    /// Where releases are.
    package static let releases = "https://github.com/SoumilB7/kore/releases"

    /// The release folders to look in, in order: this Kore's version's, then the latest.
    package static func bases(version: String?) -> [URL] {
        let own = version.map { "\(releases)/download/v\($0)" }
        return ([own].compactMap { $0 } + ["\(releases)/latest/download"]).compactMap(URL.init(string:))
    }

    /// Fetches a release file (tests: in memory).
    package typealias Fetch = @Sendable (_ url: URL) async -> Data?

    @Sendable package static func download(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// The binary for `platform`, unpacked (a temp file when it had to be), or nil.
    package static func local(
        _ platform: String, override: String? = UserDefaults.standard.string(forKey: BoxBinary.overrideKey), helper: URL? = NetSidecar.helper(),
        build: BoxHostBuild = .here, fetch: Fetch = download, key: String = KoreReleaseKey.base64
    ) async -> (url: URL, temporary: Bool)? {
        let files = FileManager.default
        let name = "kore-tailnet-" + platform
        var found: URL?
        if let path = override, !path.isEmpty {
            let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            found = [name, name + ".xz"].map { folder.appendingPathComponent($0) }.first { files.fileExists(atPath: $0.path) }
        }
        if found == nil, platform == "macos-arm64", let helper { found = helper }
        let kept = build.folder.appendingPathComponent("\(build.label)-\(name)")
        if found == nil, build.label != "dev", files.isExecutableFile(atPath: kept.path) { found = kept }
        if found == nil, let checkout = build.builtFrom {
            found = [name, name + ".xz"].map { checkout.appendingPathComponent("build/release/" + $0) }.first { files.fileExists(atPath: $0.path) }
        }
        if let found { return unpacked(found, name: name) }
        // The release's, checked against its signed sums. This Kore's own release first; the
        // latest only when that one has none (not published, or before releases carried it).
        for base in bases(version: build.version) {
            guard let sums = await fetch(base.appendingPathComponent("SHA256SUMS")),
                  let signature = await fetch(base.appendingPathComponent("SHA256SUMS.sig")),
                  let manifest = try? ReleaseManifest.verified(sums: sums, signature: signature, key: key),
                  manifest.files[asset(platform)] != nil
            else { continue }
            // Listed and signed: this one or nothing (a bad file never falls back to another).
            return await take(manifest, from: base, platform: platform, build: build, fetch: fetch)
        }
        return nil
    }

    /// The release's file, checked against `manifest`, unpacked; kept under this Kore's label only
    /// when the release is this Kore's own version.
    private static func take(_ manifest: ReleaseManifest, from base: URL, platform: String, build: BoxHostBuild, fetch: Fetch) async -> (url: URL, temporary: Bool)? {
        let files = FileManager.default
        let name = "kore-tailnet-" + platform
        guard let data = await fetch(base.appendingPathComponent(asset(platform))) else { return nil }
        let temp = files.temporaryDirectory.appendingPathComponent("\(asset(platform)).\(UUID().uuidString.prefix(8))")
        defer { try? files.removeItem(at: temp) }
        guard (try? data.write(to: temp)) != nil, (try? manifest.check(temp, as: asset(platform))) != nil,
              let plain = platform.hasPrefix("linux-") ? try? BoxBinary.unxz(data) : data
        else { return nil }
        let kept = build.folder.appendingPathComponent("\(build.label)-\(name)")
        if build.label != "dev", manifest.version == build.version, (try? files.createDirectory(at: build.folder, withIntermediateDirectories: true)) != nil,
           (try? plain.write(to: kept)) != nil, (try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kept.path)) != nil {
            return (kept, false)
        }
        let out = files.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))")
        guard (try? plain.write(to: out)) != nil, (try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out.path)) != nil else { return nil }
        return (out, true)
    }

    private static func unpacked(_ file: URL, name: String) -> (url: URL, temporary: Bool)? {
        guard file.pathExtension == "xz" else { return (file, false) }
        guard let data = try? Data(contentsOf: file), let plain = try? BoxBinary.unxz(data) else { return nil }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))")
        guard (try? plain.write(to: temp)) != nil else { return nil }
        return (temp, true)
    }
}
