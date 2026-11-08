import Foundation

/// kore-host built on this Mac, from the source this Kore was built from, the first time a box
/// needs one: a Linux box's with Swift's static Linux SDK (the "Linux kit": swiftly, the pinned
/// open-source toolchain and its SDK, installed to the user's home once, with consent), a Mac
/// box's with the Mac's own toolchain. Each result is kept in
/// `~/Library/Application Support/Kore/kore-host/<version>-<platform>`, so the next Set up or
/// Update is instant; older versions' are pruned. Builds run at utility QoS, their output in a log
/// beside the result.
package struct BoxHostBuild: Sendable {
    /// Runs a program (its folder, its output appended to a log): what it printed and its status.
    /// Tests stand in for it.
    package typealias Runner = @Sendable (_ program: String, _ arguments: [String], _ folder: URL?, _ log: URL?) async -> BoxRan

    /// The toolchain the Linux builds use: the one build-app.sh names.
    package static let swift = "6.4.2"
    package static let repository = "https://github.com/SoumilB7/kore.git"
    /// The Info.plist key build-app.sh writes the source's full commit into.
    package static let commitKey = "KoreSourceCommit"
    /// Who signs swiftly's installer.
    static let swiftlySigner = "Developer ID Installer: Swift Open Source (V9AUD2URP3)"
    static let swiftlyPackage = "https://download.swift.org/swiftly/darwin/swiftly.pkg"
    static let releasesIndex = "https://www.swift.org/api/v1/install/releases.json"

    package var run: Runner
    /// Where `swiftly` and `~/Library/Developer/Toolchains` are.
    package var home: URL
    /// Kore's Application Support folder: `kore-host/` (results, logs, scratch) and `kore-host-src/`.
    package var support: URL
    /// Where open-source toolchains are looked for, in order.
    package var toolchains: [URL]
    /// The Mac's own swift, for Mac boxes.
    package var macSwift = "/usr/bin/swift"
    package var git = "/usr/bin/git"
    package var curl = "/usr/bin/curl"
    /// This Kore's version and source commit (Info.plist), when it has them.
    package var version: String?
    package var commit: String?
    /// The checkout this Kore was compiled in, used when it's still there at that commit.
    package var builtFrom: URL?

    package init(
        run: @escaping Runner = BoxHostBuild.system, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kore"),
        toolchains: [URL]? = nil, version: String?, commit: String?, builtFrom: URL?
    ) {
        self.run = run
        self.home = home
        self.support = support
        self.toolchains = toolchains ?? [
            home.appendingPathComponent("Library/Developer/Toolchains"), URL(fileURLWithPath: "/Library/Developer/Toolchains"),
        ]
        self.version = version
        self.commit = commit
        self.builtFrom = builtFrom
    }

    /// This Kore's: its Info.plist, and the checkout it was compiled in.
    package static var here: BoxHostBuild {
        let info = Bundle.main
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let commit = (info.object(forInfoDictionaryKey: commitKey) as? String).flatMap { $0.count == 40 ? $0 : nil }
        return BoxHostBuild(
            version: info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, commit: commit,
            builtFrom: FileManager.default.fileExists(atPath: checkout.appendingPathComponent("Package.swift").path) ? checkout : nil)
    }

    /// The Linux kit isn't here and the user hasn't said yes to it.
    package struct KitNeeded: Error, Equatable {}

    // MARK: The cache

    var folder: URL { support.appendingPathComponent("kore-host") }
    var source: URL { support.appendingPathComponent("kore-host-src") }
    /// This Kore's name for its results: `0.2.3-d3322b3`, or `dev` when it knows neither.
    var label: String {
        let parts = [version, commit.map { String($0.prefix(7)) }].compactMap { $0 }
        return parts.isEmpty ? "dev" : parts.joined(separator: "-")
    }

    package func cachedFile(_ platform: String) -> URL { folder.appendingPathComponent("\(label)-\(platform)") }
    package func log(_ platform: String) -> URL { folder.appendingPathComponent("\(label)-\(platform).log") }
    var kitLog: URL { folder.appendingPathComponent("linux-kit.log") }

    /// The kept build for `platform`, when this Kore knows its version (a development run doesn't,
    /// and builds again).
    package func cached(_ platform: String) -> URL? {
        guard label != "dev" else { return nil }
        let file = cachedFile(platform)
        return FileManager.default.isExecutableFile(atPath: file.path) ? file : nil
    }

    /// Everything older versions left in the cache; this version's files, the scratch folders and
    /// the kit's log stay.
    func prune() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where !name.hasPrefix(".") && !name.hasPrefix(label + "-") && name != kitLog.lastPathComponent {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: Building

    /// "Linux arm64", "macOS x86_64".
    package static func name(_ platform: String) -> String {
        let parts = platform.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return platform }
        let arch = parts[1] == "aarch64" ? "arm64" : parts[1]
        return (parts[0] == "linux" ? "Linux " : "macOS ") + arch
    }

    /// Builds kore-host for `platform` and keeps it: the kit first for Linux (installed only with
    /// `mayInstallKit`), then the source, then the build, each step said as it starts.
    package func build(
        _ platform: String, mayInstallKit: Bool, step: @escaping @Sendable (String) async -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let linux = platform.hasPrefix("linux-")
        let arch = String(platform.split(separator: "-", maxSplits: 1).last ?? "")
        var swift = macSwift
        if linux {
            swift = try await BoxBuilds.shared.once("linux-kit") { try await linuxSwift(mayInstall: mayInstallKit, step: step) }
        }
        let source = try await checkout(step: step)

        let log = log(platform)
        try? FileManager.default.removeItem(at: log)
        let options =
            linux
            ? ["--swift-sdk", "\(arch)-swift-linux-musl", "-c", "release", "--product", "kore-host",
               "--scratch-path", folder.appendingPathComponent(".build-linux").path]
            : ["-c", "release", "--product", "kore-host", "--arch", arch,
               "--scratch-path", folder.appendingPathComponent(".build-macos").path]
        let strip = linux ? ["-Xlinker", "--strip-all"] : ["-Xlinker", "-dead_strip"]
        let built = await timed("Building kore-host for \(Self.name(platform))", step) {
            await run(swift, ["build"] + options + strip, source, log)
        }
        guard built.ok else { throw BoxSetup.Failure(message: "Couldn't build kore-host", fix: .showLog(log.path)) }
        let bin = await run(swift, ["build"] + options + ["--show-bin-path"], source, nil)
        let product = URL(fileURLWithPath: bin.lastLine).appendingPathComponent("kore-host")
        guard bin.ok, FileManager.default.isExecutableFile(atPath: product.path) else {
            throw BoxSetup.Failure(message: "Couldn't build kore-host", fix: .showLog(log.path))
        }
        let kept = cachedFile(platform)
        let temp = folder.appendingPathComponent(".\(kept.lastPathComponent).\(UUID().uuidString.prefix(8))")
        try FileManager.default.copyItem(at: product, to: temp)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
        _ = try? FileManager.default.removeItem(at: kept)
        try FileManager.default.moveItem(at: temp, to: kept)
        prune()
        return kept
    }

    /// Says `line…` now and `line… N min` each minute while `work` runs.
    private func timed<T: Sendable>(_ line: String, _ step: @escaping @Sendable (String) async -> Void, _ work: () async -> T) async -> T {
        await step(line + "…")
        let ticker = Task {
            var minutes = 0
            while true {
                try await Task.sleep(for: .seconds(60))
                minutes += 1
                await step("\(line)… \(minutes) min")
            }
        }
        defer { ticker.cancel() }
        return await work()
    }

    // MARK: The source

    /// The source at this Kore's commit: the checkout it was compiled in when it's at that commit
    /// (or as it is, for a development run that knows none), else a shallow fetch of that commit
    /// (or of the version's tag) into `kore-host-src`, kept for next time.
    func checkout(step: @escaping @Sendable (String) async -> Void) async throws -> URL {
        if let builtFrom {
            guard let commit else { return builtFrom }
            if await head(builtFrom) == commit { return builtFrom }
        }
        guard let want = commit ?? version.map({ "refs/tags/v" + $0 }) else {
            throw BoxSetup.Failure(message: "This Kore doesn't know which source it was built from")
        }
        if let commit, await head(source) == commit { return source }
        await step("Getting Kore's source…")
        let fm = FileManager.default
        try? fm.removeItem(at: source)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let log = folder.appendingPathComponent("\(label)-source.log")
        for arguments in [["init", "-q"], ["remote", "add", "origin", Self.repository], ["fetch", "-q", "--depth", "1", "origin", want],
                          ["checkout", "-q", "--detach", "FETCH_HEAD"]] {
            let ran = await run(git, arguments, source, log)
            guard ran.ok else {
                try? fm.removeItem(at: source)
                throw BoxSetup.Failure(message: "Couldn't get Kore's source" + (ran.lastLine.isEmpty ? "" : ": " + ran.lastLine))
            }
        }
        return source
    }

    private func head(_ checkout: URL) async -> String? {
        guard FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".git").path) else { return nil }
        let ran = await run(git, ["rev-parse", "HEAD"], checkout, nil)
        return ran.ok ? ran.lastLine : nil
    }

    // MARK: The Linux kit

    var toolchainName: String { "swift-\(Self.swift)-RELEASE" }
    var swiftly: URL { home.appendingPathComponent(".swiftly/bin/swiftly") }

    /// The pinned open-source toolchain's swift, where it's installed.
    func toolchainSwift() -> String? {
        toolchains.map { $0.appendingPathComponent("\(toolchainName).xctoolchain/usr/bin/swift").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func hasSDK(_ swift: String) async -> Bool {
        let ran = await run(swift, ["sdk", "list"], nil, nil)
        return ran.ok && ran.output.contains("\(toolchainName)_static-linux")
    }

    /// Whether this Mac can build for Linux now, without installing anything.
    package func kitReady() async -> Bool {
        guard let swift = toolchainSwift() else { return false }
        return await hasSDK(swift)
    }

    /// The toolchain's swift with its Linux SDK, installing what's missing when allowed.
    func linuxSwift(mayInstall: Bool, step: @escaping @Sendable (String) async -> Void) async throws -> String {
        if let swift = toolchainSwift(), await hasSDK(swift) { return swift }
        guard mayInstall else { throw KitNeeded() }
        let failed = BoxSetup.Failure(message: "Couldn't install Swift's Linux kit", fix: .showLog(kitLog.path))
        return try await timed("Installing Swift's Linux kit", step) { () async -> Result<String, BoxSetup.Failure> in
            if toolchainSwift() == nil {
                guard await installSwiftly(), await run(swiftly.path, ["install", Self.swift, "--assume-yes"], nil, kitLog).ok,
                    toolchainSwift() != nil
                else { return .failure(failed) }
            }
            guard let swift = toolchainSwift() else { return .failure(failed) }
            if await !hasSDK(swift) {
                guard let sdk = await staticSDK(), await run(swift, ["sdk", "install", sdk.url, "--checksum", sdk.checksum], nil, kitLog).ok,
                    await hasSDK(swift)
                else { return .failure(failed) }
            }
            return .success(swift)
        }.get()
    }

    /// swiftly in the user's home, no sudo: its signed installer, then `init` without touching
    /// the shell profile or installing a toolchain of its own.
    private func installSwiftly() async -> Bool {
        if FileManager.default.isExecutableFile(atPath: swiftly.path) { return true }
        let pkg = folder.appendingPathComponent("swiftly.pkg")
        defer { try? FileManager.default.removeItem(at: pkg) }
        guard await run(curl, ["-fsSL", "-o", pkg.path, Self.swiftlyPackage], nil, kitLog).ok else { return false }
        let signed = await run("/usr/sbin/pkgutil", ["--check-signature", pkg.path], nil, kitLog)
        guard signed.ok, signed.output.contains(Self.swiftlySigner) else { return false }
        guard await run("/usr/sbin/installer", ["-pkg", pkg.path, "-target", "CurrentUserHomeDirectory"], nil, kitLog).ok else { return false }
        return await run(swiftly.path, ["init", "--no-modify-profile", "--skip-install", "--quiet-shell-followup", "--assume-yes"], nil, kitLog).ok
    }

    /// The static Linux SDK's address and checksum for the pinned toolchain, from swift.org's
    /// release list; `swift sdk install --checksum` checks the download against it.
    private func staticSDK() async -> (url: String, checksum: String)? {
        let ran = await run(curl, ["-fsSL", Self.releasesIndex], nil, nil)
        guard ran.ok else { return nil }
        return Self.staticSDK(releases: Data(ran.output.utf8), swift: Self.swift)
    }

    package static func staticSDK(releases: Data, swift: String) -> (url: String, checksum: String)? {
        guard let list = try? JSONSerialization.jsonObject(with: releases) as? [[String: Any]],
            let release = list.first(where: { $0["name"] as? String == swift }),
            let tag = release["tag"] as? String,
            let sdk = (release["platforms"] as? [[String: Any]])?.first(where: { $0["platform"] as? String == "static-sdk" }),
            let version = sdk["version"] as? String, let checksum = sdk["checksum"] as? String,
            checksum.count == 64, checksum.allSatisfy(\.isHexDigit)
        else { return nil }
        let url = "https://download.swift.org/\(tag.lowercased())/static-sdk/\(tag)/\(tag)_static-linux-\(version).artifactbundle.tar.gz"
        return (url, checksum)
    }

    // MARK: Running

    /// The real runner: the program at utility QoS, prompts off, its output appended to the log.
    package static let system: Runner = { program, arguments, folder, log in
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: program)
                process.arguments = arguments
                if let folder { process.currentDirectoryURL = folder }
                process.qualityOfService = .utility
                var environment = ProcessInfo.processInfo.environment
                environment["GIT_TERMINAL_PROMPT"] = "0"
                process.environment = environment
                let out = Pipe()
                process.standardOutput = out
                process.standardError = out
                process.standardInput = FileHandle.nullDevice
                append(log, "$ \(([program] + arguments).joined(separator: " "))\n")
                do { try process.run() } catch {
                    append(log, error.localizedDescription + "\n")
                    return continuation.resume(returning: BoxRan(status: 127, output: error.localizedDescription))
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                append(log, String(decoding: data, as: UTF8.self))
                continuation.resume(returning: BoxRan(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            }
        }
    }

    private static func append(_ log: URL?, _ text: String) {
        guard let log else { return }
        if !FileManager.default.fileExists(atPath: log.path) {
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: log) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }
}

/// One build per result at a time: a second box asking for the same kore-host (or the kit) waits
/// for the first's.
actor BoxBuilds {
    static let shared = BoxBuilds()
    private var running: [String: Task<String, Error>] = [:]

    func once(_ key: String, _ work: @escaping @Sendable () async throws -> String) async throws -> String {
        if let task = running[key] { return try await task.value }
        let task = Task { try await work() }
        running[key] = task
        defer { running[key] = nil }
        return try await task.value
    }
}
