import Foundation
import LinkProtocol
import SystemConfiguration

/// A command's run on this Mac (`ssh`, `scp`): its exit status and what it printed.
package struct BoxRan: Sendable, Equatable {
    package var status: Int32
    package var output: String

    package init(status: Int32, output: String = "") {
        self.status = status
        self.output = output
    }

    package var ok: Bool { status == 0 }
    package var lastLine: String {
        output.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

/// ssh and scp to a box, without asking anything (`BatchMode`): the user's own SSH config and agent
/// do the rest. Tests point it at stand-ins.
package struct BoxShell: Sendable {
    package var ssh: String
    package var scp: String

    package init(ssh: String = SSHTransport.ssh, scp: String = "/usr/bin/scp") {
        self.ssh = ssh
        self.scp = scp
    }

    /// `command` run by the box's shell, in its home.
    package func run(_ alias: String, _ command: String) async -> BoxRan {
        await Self.process(ssh, ["-T", "-o", "BatchMode=yes", "--", alias, command])
    }

    /// Copies a file to a path under the box's home.
    package func copy(_ file: URL, to alias: String, path: String) async -> BoxRan {
        await Self.process(scp, ["-q", "-o", "BatchMode=yes", "--", file.path, alias + ":" + path])
    }

    private static func process(_ executable: String, _ arguments: [String]) async -> BoxRan {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let out = Pipe()
                process.standardOutput = out
                process.standardError = out
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    return continuation.resume(returning: BoxRan(status: 127, output: error.localizedDescription))
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: BoxRan(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

/// Puts kore-host on a box from this Mac, over its SSH: the box's CPU, the binary copied to
/// `~/.local/bin/kore-host` (beside it, then moved over, so a running one isn't touched), the
/// service installed and (re)started, and this Mac's grant. Update is the same without the grant.
package struct BoxSetup: Sendable {
    package var alias: String
    /// This Mac's grant name on the box.
    package var grant: String
    package var shell: BoxShell
    /// The binary for a CPU (`x86_64`, `aarch64`), and whether it's a temp file to remove after.
    package var binary: @Sendable (String) async throws -> (url: URL, temporary: Bool)

    package init(
        alias: String, grant: String, shell: BoxShell = BoxShell(),
        binary: @escaping @Sendable (String) async throws -> (url: URL, temporary: Bool) = { try await BoxBinary.local(arch: $0) }
    ) {
        self.alias = alias
        self.grant = grant
        self.shell = shell
        self.binary = binary
    }

    /// Where it goes, under the box's home (what `SSHTransport.defaultCommand` runs).
    static let target = ".local/bin/kore-host"

    package struct Failure: Error, Equatable, Sendable {
        package var message: String
        package init(message: String) { self.message = message }
    }

    /// Sets the box up (`allow`: and grants this Mac full control), saying each step as it starts.
    package func run(allow: Bool, step: @MainActor @Sendable (String) -> Void) async throws(Failure) {
        await step("Checking \(alias)…")
        let uname = await shell.run(alias, "uname -sm")
        guard uname.ok else { throw fail(uname, "Can't reach \(alias)") }
        guard let arch = BoxBinary.arch(uname: uname.lastLine) else { throw Failure(message: "\(alias) isn't a Linux box Kore knows (\(uname.lastLine))") }
        let file: (url: URL, temporary: Bool)
        do { file = try await binary(arch) } catch { throw Failure(message: "Couldn't get kore-host for \(arch): \(error.localizedDescription)") }
        defer { if file.temporary { try? FileManager.default.removeItem(at: file.url) } }

        await step("Copying kore-host…")
        let folder = await shell.run(alias, "mkdir -p .local/bin")
        guard folder.ok else { throw fail(folder, "Couldn't make ~/.local/bin on \(alias)") }
        let copied = await shell.copy(file.url, to: alias, path: Self.target + ".new")
        guard copied.ok else { throw fail(copied, "Couldn't copy kore-host to \(alias)") }
        let moved = await shell.run(alias, "chmod 755 \(Self.target).new && mv -f \(Self.target).new \(Self.target)")
        guard moved.ok else { throw fail(moved, "Couldn't put kore-host in place on \(alias)") }

        await step("Starting…")
        let installed = await shell.run(alias, "\(Self.target) install-service")
        guard installed.ok else { throw fail(installed, "kore-host didn't start on \(alias)") }
        if allow {
            let allowed = await shell.run(alias, "\(Self.target) allow '\(grant)' --control full")
            guard allowed.ok else { throw fail(allowed, "\(alias) didn't take this Mac's grant") }
        }
    }

    /// `systemctl --user start kore-host`: a stopped service started again.
    package func start() async throws(Failure) {
        let started = await shell.run(alias, "systemctl --user start kore-host")
        guard started.ok else { throw fail(started, "kore-host didn't start on \(alias)") }
    }

    /// The box's own last words when it said any, else `fallback`.
    private func fail(_ ran: BoxRan, _ fallback: String) -> Failure {
        ran.status == AttachExit.sshFailed || ran.lastLine.isEmpty ? Failure(message: fallback) : Failure(message: fallback + ": " + ran.lastLine)
    }

    // MARK: This Mac's grant

    /// This Mac's grant name: its local host name ("Soumils-MacBook-Pro"), as a grant's name may be.
    package static func macGrantName() -> String {
        let name = (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? ProcessInfo.processInfo.hostName
        let first = name.split(separator: ".").first.map(String.init) ?? name
        let kept = String(first.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0)) }.prefix(64))
        return kept.isEmpty ? "mac" : kept
    }

    private static func grantKey(_ alias: String) -> String { "boxGrant." + alias }
    private static func commandKey(_ alias: String) -> String { "boxKoreHost." + alias }

    /// The grant this Mac uses on a box: the one its setup made, else this Mac's name.
    package static func grant(for alias: String, defaults: UserDefaults? = .standard) -> String {
        defaults?.string(forKey: grantKey(alias)) ?? macGrantName()
    }

    package static func setGrant(_ grant: String, for alias: String, defaults: UserDefaults? = .standard) {
        defaults?.set(grant, forKey: grantKey(alias))
    }

    /// kore-host's path on the box: `defaults write <Kore> boxKoreHost.<alias> <path>`, else
    /// `~/.local/bin/kore-host`.
    package static func command(for alias: String, defaults: UserDefaults? = .standard) -> String {
        defaults?.string(forKey: commandKey(alias)) ?? SSHTransport.defaultCommand
    }

    /// What this Mac keeps for a box it forgets.
    package static func forget(_ alias: String, defaults: UserDefaults?) {
        defaults?.removeObject(forKey: grantKey(alias))
        defaults?.removeObject(forKey: commandKey(alias))
    }
}

/// The kore-host binary for a box: a development build named by the `koreHostBinary` default; one
/// Kore carries (`Contents/Resources/kore-host-linux-<arch>.xz`, in builds made with
/// `KORE_BUNDLE_BOX_HOST=1`); else this version's from its GitHub release, checked against the
/// SHA-256 the build wrote into Info.plist (`KoreHostSHA256-<arch>`) and kept for next time.
package enum BoxBinary {
    package static let overrideKey = "koreHostBinary"
    package static let releases = "https://github.com/SoumilB7/kore/releases/download"

    /// The box's CPU from `uname -sm` ("Linux x86_64"): nil for another system or CPU.
    package static func arch(uname: String) -> String? {
        let words = uname.split(separator: " ").map(String.init)
        guard words.first == "Linux", let machine = words.last else { return nil }
        switch machine {
        case "x86_64", "amd64": return "x86_64"
        case "aarch64", "arm64": return "aarch64"
        default: return nil
        }
    }

    /// The binary for `arch`, unpacked to a temp file when it's compressed.
    package static func local(
        arch: String, override: String? = UserDefaults.standard.string(forKey: overrideKey), bundle: Bundle = .main
    ) async throws -> (url: URL, temporary: Bool) {
        let packed: URL
        if let path = override, !path.isEmpty {
            packed = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else if let url = bundle.url(forResource: "kore-host-linux-\(arch)", withExtension: "xz") {
            packed = url
        } else {
            packed = try await download(arch: arch, bundle: bundle)
        }
        guard packed.pathExtension == "xz" else { return (packed, false) }
        let data = try unxz(Data(contentsOf: packed))
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("kore-host-\(arch)-\(UUID().uuidString.prefix(8))")
        try data.write(to: temp)
        return (temp, true)
    }

    /// This version's binary from its release, once: kept under Application Support, and used only
    /// when its SHA-256 is the one this build recorded.
    static func download(arch: String, bundle: Bundle) async throws -> URL {
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            let expected = (bundle.object(forInfoDictionaryKey: "KoreHostSHA256-\(arch)") as? String)?.lowercased()
        else { throw BoxBinaryError("This Kore build has no kore-host for \(arch)") }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let kept = support.appendingPathComponent("Kore/kore-host/v\(version)/kore-host-linux-\(arch).xz")
        if let data = try? Data(contentsOf: kept), HostWire.sha256(data) == expected { return kept }
        guard let url = URL(string: "\(releases)/v\(version)/kore-host-linux-\(arch).xz") else { throw BoxBinaryError("No release address") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BoxBinaryError("Release v\(version) has no kore-host for \(arch)") }
        guard HostWire.sha256(data) == expected else { throw BoxBinaryError("The downloaded kore-host isn't the one this Kore was built with") }
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: kept, options: .atomic)
        return kept
    }

    /// An `.xz` file's contents (Compression's LZMA reads the xz format).
    package static func unxz(_ data: Data) throws -> Data {
        try (data as NSData).decompressed(using: .lzma) as Data
    }
}

/// Why there's no kore-host binary to put on a box, in a line.
package struct BoxBinaryError: LocalizedError {
    package let message: String
    package init(_ message: String) { self.message = message }
    package var errorDescription: String? { message }
}
