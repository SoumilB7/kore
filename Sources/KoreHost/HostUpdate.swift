import Foundation
import KoreCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// `kore-host update` and `kore-host verify`: a release's assets checked against its signed
/// `SHA256SUMS` (Kore's release key, compiled in), then the new binary put in place of this one
/// in a single rename, so a failure at any step leaves the old one as it was.
package struct HostUpdate {
    /// Where releases are when no file is given: the latest one on GitHub.
    package static let latest = "https://github.com/SoumilB7/kore/releases/latest/download"

    /// This kore-host's version.
    package var current = HostVersion.string
    /// The binary to replace.
    package var target: URL
    /// The release key (base64, raw 32 bytes).
    package var key = KoreReleaseKey.base64
    package var platform = HostUpdate.platform
    /// Runs a command (curl, the new binary's `--version`, the service manager).
    package var run: HostRunner = HostService.system
    /// Writes an `.xz` file's contents to a file.
    package var unpack: @Sendable (_ xz: URL, _ to: URL) throws -> Void = HostUpdate.unxz

    package init(target: URL) {
        self.target = target
    }

    /// The asset this machine runs: `kore-host-linux-x86_64.xz`.
    package var asset: String { "kore-host-\(platform).xz" }

    package static var platform: String {
        #if os(Linux)
        #if arch(arm64)
        "linux-aarch64"
        #else
        "linux-x86_64"
        #endif
        #else
        "macos-arm64"
        #endif
    }

    /// `SHA256SUMS` beside `file` (or `file` itself), checked against `SHA256SUMS.sig` beside it.
    package func manifest(beside file: URL) throws -> ReleaseManifest {
        let folder = file.deletingLastPathComponent()
        let sums = folder.appendingPathComponent("SHA256SUMS"), sig = folder.appendingPathComponent("SHA256SUMS.sig")
        guard let sumsData = try? Data(contentsOf: sums) else { throw ReleaseError.missing("SHA256SUMS") }
        guard let sigData = try? Data(contentsOf: sig) else { throw ReleaseError.missing("SHA256SUMS.sig") }
        return try ReleaseManifest.verified(sums: sumsData, signature: sigData, key: key)
    }

    /// `kore-host verify <file>`: the manifest's signature, then `file` against its entry, or for
    /// `SHA256SUMS` itself every listed file that's beside it. The lines to print.
    package func verify(_ file: URL) throws -> [String] {
        let manifest = try manifest(beside: file)
        let folder = file.deletingLastPathComponent()
        let names = file.lastPathComponent == "SHA256SUMS"
            ? manifest.files.keys.sorted().filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            : [file.lastPathComponent]
        for name in names { try manifest.check(folder.appendingPathComponent(name), as: name) }
        return ["kore \(manifest.version) (\(manifest.commit.prefix(7))): signed by Kore's release key"] + names.map { "ok \($0)" }
    }

    /// What `apply` did.
    package enum Outcome: Equatable {
        case updated(from: String, to: String)
        case same(String)
    }

    /// Checks `file` (this platform's `.xz`, with `SHA256SUMS` and its `.sig` beside it), refuses
    /// an older version unless `force`, and swaps the new binary in. Nothing changes on a failure.
    package func apply(_ file: URL, force: Bool) throws -> Outcome {
        let manifest = try manifest(beside: file)
        try manifest.check(file, as: asset)
        if !force {
            if ReleaseManifest.newer(current, than: manifest.version) { throw ReleaseError.downgrade(manifest.version, current) }
            if manifest.version == current { return .same(current) }
        }
        // Beside the target, so the rename stays on one file system.
        let staged = target.deletingLastPathComponent().appendingPathComponent(".kore-host.new-\(getpid())")
        try? FileManager.default.removeItem(at: staged)
        do {
            try unpack(file, staged)
            guard chmod(staged.path, 0o755) == 0 else { throw HostUpdateError.failed("chmod", String(cString: strerror(errno))) }
            let said = run([staged.path, "--version"])
            guard said.ok, said.output.hasPrefix("kore-host \(manifest.version) ") else {
                throw ReleaseError.wrongBinary(said.lastLine)
            }
            guard rename(staged.path, target.path) == 0 else { throw HostUpdateError.failed("rename", String(cString: strerror(errno))) }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return .updated(from: current, to: manifest.version)
    }

    /// The latest release's `SHA256SUMS`, its `.sig` and this platform's asset, into `folder`
    /// (`KORE_RELEASE_URL` in place of GitHub's). The asset's file.
    package func download(into folder: URL, from base: String = ProcessInfo.processInfo.environment["KORE_RELEASE_URL"] ?? HostUpdate.latest) throws -> URL {
        for name in ["SHA256SUMS", "SHA256SUMS.sig", asset] {
            let ran = run(["curl", "-fsSL", "--retry", "2", "-o", folder.appendingPathComponent(name).path, base + "/" + name])
            guard ran.ok else { throw HostUpdateError.failed("downloading \(name)", ran.status == 127 ? "needs curl" : ran.lastLine) }
        }
        return folder.appendingPathComponent(asset)
    }

    /// The running daemon onto the new binary, as it was started. The line to print.
    package static func restart(paths: HostPaths, home: URL, run: HostRunner = HostService.system) -> String {
        guard HostLock.held(paths.lock) else { return "kore-host isn't running: it starts on the new one" }
        switch HostService.installed(paths) {
        case nil, .systemd?:
            return run(["systemctl", "--user", "restart", HostService.unitName]).ok
                ? "kore-host restarted" : "restart it: systemctl --user restart kore-host"
        case .launchd?:
            let domain = HostService.domain(run: run)
            return run(["launchctl", "kickstart", "-k", "\(domain)/\(HostService.agentLabel)"]).ok
                ? "kore-host restarted" : "restart it: launchctl kickstart -k \(domain)/\(HostService.agentLabel)"
        case .onDemand?:
            HostService.stopOnDemand(paths)
            return "kore-host stopped: it starts on the new one when Kore connects"
        }
    }

    /// `xz -dc`, its output straight into the file.
    package static let unxz: @Sendable (URL, URL) throws -> Void = { xz, to in
        guard FileManager.default.createFile(atPath: to.path, contents: nil, attributes: [.posixPermissions: 0o700]) else {
            throw HostUpdateError.failed("writing \(to.lastPathComponent)", "no room or no permission")
        }
        let out = try FileHandle(forWritingTo: to)
        defer { try? out.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xz", "-dc", xz.path]
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw HostUpdateError.failed("xz", "needs xz (xz-utils)") }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HostUpdateError.failed("xz", process.terminationStatus == 127 ? "needs xz (xz-utils)" : "couldn't unpack \(xz.lastPathComponent)")
        }
    }
}

package enum HostUpdateError: Error, Equatable, CustomStringConvertible {
    case failed(String, String)
    package var description: String {
        switch self {
        case .failed(let what, let why): "\(what) failed: \(why)"
        }
    }
}
