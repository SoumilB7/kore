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
/// do the rest. A typed destination's user and port go as options, its host as one word after
/// `--`. Tests point it at stand-ins.
package struct BoxShell: Sendable {
    package var ssh: String
    package var scp: String

    package init(ssh: String = SSHTransport.ssh, scp: String = "/usr/bin/scp") {
        self.ssh = ssh
        self.scp = scp
    }

    static let options = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]

    /// `command` run by the box's shell, in its home; `input` on its stdin.
    package func run(_ alias: String, _ command: String, input: String? = nil) async -> BoxRan {
        let address = BoxAddress(alias)
        return await Self.process(ssh, Self.options + (address?.options ?? []) + ["--", address?.host ?? alias, command], input: input)
    }

    /// An sh script run on the box (`sh -s`, the script on stdin): the same whatever the login
    /// shell is.
    package func script(_ alias: String, _ script: String) async -> BoxRan {
        await run(alias, "sh -s", input: script)
    }

    /// Copies a file to a path under the box's home.
    package func copy(_ file: URL, to alias: String, path: String) async -> BoxRan {
        let address = BoxAddress(alias)
        return await Self.process(scp, ["-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"] + (address?.options ?? []) + ["--", file.path, (address?.host ?? alias) + ":" + path])
    }

    /// Runs `ssh` (whatever program it names) with `arguments`.
    func process(_ arguments: [String], input: String?) async -> BoxRan { await Self.process(ssh, arguments, input: input) }

    static func process(_ executable: String, _ arguments: [String], input: String? = nil) async -> BoxRan {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let out = Pipe()
                process.standardOutput = out
                process.standardError = out
                let stdin = input.map { _ in Pipe() }
                process.standardInput = stdin ?? FileHandle.nullDevice
                do { try process.run() } catch {
                    return continuation.resume(returning: BoxRan(status: 127, output: error.localizedDescription))
                }
                if let stdin, let input {
                    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                    try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                    try? stdin.fileHandleForWriting.close()
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: BoxRan(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

/// What fixes a box's line: the one action beside it.
package enum BoxFix: Equatable, Sendable {
    /// Copy kore-host there, install its service and grant this Mac.
    case setUp
    /// Start the stopped daemon (`kore-host start`).
    case start
    /// Copy this Kore's kore-host there and restart it.
    case update
    /// The same while chats there are working (their turns end with the restart).
    case setUpAnyway, updateAnyway
    /// Install the CLIs there and sign them in.
    case setUpAgents
    /// What's different from this Mac.
    case differences(Int)
    /// Find the box again (it was unreachable, or the step may pass now).
    case tryAgain
    /// A command for the user's own Terminal, copied: what Kore mustn't do itself (a key, sudo).
    case copy(String)
    /// Install a tool there that needs no password (Homebrew).
    case install(String)
    /// Install Swift's Linux kit on this Mac (the user's yes), then Set up or Update again.
    case installLinuxKit(update: Bool)
    /// Open the log a build on this Mac left.
    case showLog(String)

    package var title: String {
        switch self {
        case .setUp: "Set up"
        case .start: "Start"
        case .update: "Update"
        case .setUpAnyway: "Set up anyway"
        case .updateAnyway: "Update anyway"
        case .setUpAgents: "Set up agents"
        case .differences: "Fix"
        case .tryAgain: "Try again"
        case .copy: "Copy"
        case .install, .installLinuxKit: "Install"
        case .showLog: "Show log"
        }
    }
}

/// Puts kore-host on a box from this Mac, over its SSH, saying each step as it starts: what the
/// machine is, the right kore-host for it, copied to `~/.local/bin/kore-host` (beside it, checked
/// that it runs there, then moved over, so a running one isn't touched), installed as a service
/// (systemd, launchd, or started on demand where there's no service manager), and this Mac's
/// grant. Update is the same without the grant.
package struct BoxSetup: Sendable {
    package var alias: String
    /// This Mac's grant name on the box.
    package var grant: String
    package var shell: BoxShell
    /// The binary for a platform (`linux-x86_64`, `macos-arm64`), and whether it's a temp file to
    /// remove after.
    package var binary: @Sendable (BoxBinary.Request) async throws -> (url: URL, temporary: Bool)
    /// The user said yes to installing Swift's Linux kit, for a build that needs it.
    package var mayInstallKit = false

    package init(
        alias: String, grant: String, shell: BoxShell = BoxShell(),
        binary: @escaping @Sendable (BoxBinary.Request) async throws -> (url: URL, temporary: Bool) = { try await BoxBinary.local($0) }
    ) {
        self.alias = alias
        self.grant = grant
        self.shell = shell
        self.binary = binary
    }

    /// What a Linux box's first Set up asks before installing the kit that builds kore-host.
    package static let kitLine = "Building kore-host needs Swift's Linux kit (about 2 GB)"
    /// Where it goes, under the box's home (what `SSHTransport.defaultCommand` runs).
    static let target = ".local/bin/kore-host"
    /// Room it needs in the box's home, in KB: the binary, unpacked, and its state.
    static let room = 150 * 1024

    package struct Failure: Error, Equatable, Sendable {
        package var message: String
        package var fix: BoxFix?
        package init(message: String, fix: BoxFix? = nil) {
            self.message = message
            self.fix = fix
        }
    }

    /// How a setup went: the machine as found, and a catch to say (linger off), if any.
    package struct Done: Sendable, Equatable {
        package var machine: BoxMachine
        package var warning: String?
    }

    /// What the box is, over one ssh session; `deep` runs the CLIs' `--version` too.
    package func detect(deep: Bool = true) async throws(Failure) -> BoxMachine {
        let ran = await shell.script(alias, BoxMachine.script(deep: deep))
        guard ran.status != AttachExit.sshFailed else { throw Self.sshFailure(alias, ran.output) }
        guard let machine = BoxMachine.parse(ran.output) else {
            throw Failure(message: "\(alias) didn't answer like a shell" + (ran.lastLine.isEmpty ? "" : ": " + ran.lastLine), fix: .tryAgain)
        }
        return machine
    }

    /// Sets the box up (`allow`: and grants this Mac full control), saying each step as it starts.
    @discardableResult
    package func run(allow: Bool, step: @escaping @MainActor @Sendable (String) -> Void) async throws(Failure) -> Done {
        let retry: BoxFix = allow ? .setUp : .update
        await step("Checking \(alias)…")
        let machine = try await detect()
        if let why = machine.unsupported(alias) { throw Failure(message: why) }
        guard let platform = machine.platform else { throw Failure(message: "\(alias) runs \(machine.uname)") }
        if let free = machine.freeKB, free < Self.room {
            throw Failure(message: "\(alias) has \(free / 1024) MB free · kore-host needs about \(Self.room / 1024) MB", fix: .tryAgain)
        }

        await step("Getting kore-host for \(machine.kind)…")
        let file: (url: URL, temporary: Bool)
        do {
            file = try await binary(BoxBinary.Request(platform: platform, mayInstallKit: mayInstallKit) { await step($0) })
        } catch is BoxHostBuild.KitNeeded {
            throw Failure(message: Self.kitLine, fix: .installLinuxKit(update: !allow))
        } catch let why as Failure {
            throw why
        } catch {
            throw Failure(message: "Couldn't get kore-host for \(alias): \(error.localizedDescription)", fix: retry)
        }
        defer { if file.temporary { try? FileManager.default.removeItem(at: file.url) } }

        await step("Copying kore-host to \(alias)…")
        let folder = await shell.run(alias, "mkdir -p .local/bin")
        guard folder.ok else { throw fail(folder, "Couldn't make ~/.local/bin on \(alias)", retry) }
        let copied = await shell.copy(file.url, to: alias, path: Self.target + ".new")
        guard copied.ok else { throw fail(copied, "Couldn't copy kore-host to \(alias)", retry) }
        // It runs there before it replaces the one that does.
        let checked = await shell.run(alias, "chmod 755 \(Self.target).new && \(Self.target).new --version")
        guard checked.ok, checked.output.contains("kore-host ") else {
            _ = await shell.run(alias, "rm -f \(Self.target).new")
            throw fail(checked, "That kore-host doesn't run on \(alias)", nil)
        }
        let moved = await shell.run(alias, "mv -f \(Self.target).new \(Self.target)")
        guard moved.ok else { throw fail(moved, "Couldn't put kore-host in place on \(alias)", retry) }

        await step("Starting kore-host (\(machine.service))…")
        let installed = await shell.run(alias, "\(Self.target) install-service")
        guard installed.ok else { throw fail(installed, "kore-host didn't start on \(alias)", retry) }
        if allow {
            await step("Letting this Mac in…")
            let allowed = await shell.run(alias, "\(Self.target) allow '\(grant)' --control full")
            guard allowed.ok else { throw fail(allowed, "\(alias) didn't let this Mac in", retry) }
        }
        var found = machine
        found.koreHost = checked.output.split(whereSeparator: \.isNewline).first { $0.hasPrefix("kore-host ") }.map(String.init)
        let warning = installed.output.contains("linger is off") ? "\(alias) stops kore-host when you log out · sudo loginctl enable-linger" : nil
        return Done(machine: found, warning: warning)
    }

    /// `kore-host start`: the daemon started again, however it was installed there.
    package func start() async throws(Failure) {
        let started = await shell.run(alias, "\(Self.target) start")
        guard started.ok else { throw fail(started, "kore-host didn't start on \(alias)", .tryAgain) }
    }

    /// The box's own last words when it said any, else `fallback`; ssh's own failure, plainly.
    private func fail(_ ran: BoxRan, _ fallback: String, _ fix: BoxFix?) -> Failure {
        if ran.status == AttachExit.sshFailed { return Self.sshFailure(alias, ran.output) }
        return ran.lastLine.isEmpty ? Failure(message: fallback, fix: fix) : Failure(message: fallback + ": " + ran.lastLine, fix: fix)
    }

    /// Why ssh itself failed, in a line, with the one thing that fixes it. BatchMode never asks,
    /// so a password or a new host key shows up here.
    package static func sshFailure(_ name: String, _ said: String) -> Failure {
        let address = BoxAddress(name)
        let ssh = address?.command() ?? "ssh \(name)"
        let text = said.lowercased()
        if text.contains("remote host identification has changed") {
            let reset = "ssh-keygen -R \(address?.host ?? name)"
            return Failure(message: "\(name)'s host key changed · check it, then \(reset)", fix: .copy(reset))
        }
        if text.contains("host key verification failed") || text.contains("host key is known") {
            return Failure(message: "\(name)'s host key is new · \(ssh) once in Terminal", fix: .copy(ssh))
        }
        if text.contains("permission denied") || text.contains("too many authentication failures") {
            let copyID = address?.command("ssh-copy-id") ?? "ssh-copy-id \(name)"
            return Failure(message: "\(name) needs a key · \(copyID)", fix: .copy(copyID))
        }
        if text.contains("could not resolve hostname") || text.contains("name or service not known") {
            return Failure(message: "Can't find \(name) · check the name", fix: .tryAgain)
        }
        if text.contains("connection refused") { return Failure(message: "\(name) refused SSH", fix: .tryAgain) }
        return Failure(message: "Can't reach \(name)", fix: .tryAgain)
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

/// The kore-host binary for a box's platform (`linux-x86_64`, `linux-aarch64`, `macos-arm64`,
/// `macos-x86_64`), in this order: a development build named by the `koreHostBinary` default (a
/// file, or a folder holding `kore-host-<platform>[.xz]`); the one this version built before (the
/// cache); for a Mac like this one, the kore-host built beside Kore; else built now from this
/// Kore's source (`BoxHostBuild`).
package enum BoxBinary {
    package static let overrideKey = "koreHostBinary"

    /// What Set up asks for: the platform, whether the user said yes to Swift's Linux kit, and
    /// where to say each step.
    package struct Request: Sendable {
        package var platform: String
        package var mayInstallKit: Bool
        package var step: @Sendable (String) async -> Void

        package init(platform: String, mayInstallKit: Bool = false, step: @escaping @Sendable (String) async -> Void = { _ in }) {
            self.platform = platform
            self.mayInstallKit = mayInstallKit
            self.step = step
        }
    }

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

    /// This Mac's own platform.
    package static var here: String {
        #if arch(arm64)
        "macos-arm64"
        #else
        "macos-x86_64"
        #endif
    }

    /// The binary for the request, unpacked to a temp file when it's compressed.
    package static func local(
        _ request: Request, override: String? = UserDefaults.standard.string(forKey: overrideKey),
        beside: URL? = Bundle.main.executableURL?.deletingLastPathComponent(), build: BoxHostBuild = .here
    ) async throws -> (url: URL, temporary: Bool) {
        let platform = request.platform
        let name = "kore-host-" + platform
        var found: URL?
        if let path = override, !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                found = [name + ".xz", name].map { url.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
            } else {
                found = url
            }
        }
        if found == nil { found = build.cached(platform) }
        if found == nil, platform == here, let beside {
            let built = beside.appendingPathComponent("kore-host")
            if FileManager.default.isExecutableFile(atPath: built.path) { found = built }
        }
        let file: URL
        if let found {
            file = found
        } else {
            file = URL(fileURLWithPath: try await BoxBuilds.shared.once("build-" + platform) {
                try await build.build(platform, mayInstallKit: request.mayInstallKit, step: request.step).path
            })
        }
        guard file.pathExtension == "xz" else { return (file, false) }
        let data = try unxz(Data(contentsOf: file))
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))")
        try data.write(to: temp)
        return (temp, true)
    }

    /// An `.xz` file's contents (Compression's LZMA reads the xz format).
    package static func unxz(_ data: Data) throws -> Data {
        try (data as NSData).decompressed(using: .lzma) as Data
    }
}
