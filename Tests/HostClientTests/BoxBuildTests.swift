import Foundation
import HostClient
import Testing

/// kore-host built on this Mac for Set up: the kit (present, missing, asked for), the source, the
/// build and its cache, and where BoxBinary looks first. A stand-in runner answers for swift,
/// swiftly, git and curl; one real build runs only on purpose.
@MainActor
@Suite(.serialized)
struct BoxBuildTests {
    nonisolated static let commit = "abcdef1234567890abcdef1234567890abcdef12"

    /// What the runner was asked, and its answers: a toolchain that appears when swiftly installs
    /// it, an SDK that appears when swift installs it.
    final class Toolbox: @unchecked Sendable {
        let root: URL
        let home: URL
        let support: URL
        let checkout: URL
        let bin: URL
        private let lock = NSLock()
        private var said: [String] = []
        var sdk = true
        var buildFails = false

        init(toolchain: Bool = true, sdk: Bool = true) throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("boxbuild-\(UUID().uuidString.prefix(8))")
            home = root.appendingPathComponent("home")
            support = root.appendingPathComponent("support")
            checkout = root.appendingPathComponent("checkout")
            bin = root.appendingPathComponent("bin")
            self.sdk = sdk
            for dir in [home, support, checkout.appendingPathComponent(".git"), bin] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            if toolchain { try addToolchain() }
        }

        var swift: URL { home.appendingPathComponent("Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain/usr/bin/swift") }

        func addToolchain() throws {
            try FileManager.default.createDirectory(at: swift.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: swift.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        }

        var calls: [String] { lock.withLock { said } }

        func build(version: String? = "0.2.3", commit: String? = BoxBuildTests.commit, builtFrom: Bool = true) -> BoxHostBuild {
            var build = BoxHostBuild(
                run: { [self] program, arguments, folder, _ in answer(program, arguments, folder) }, home: home, support: support,
                toolchains: [home.appendingPathComponent("Library/Developer/Toolchains")], version: version, commit: commit,
                builtFrom: builtFrom ? checkout : nil)
            build.macSwift = "/usr/bin/swift"
            return build
        }

        private func answer(_ program: String, _ arguments: [String], _ folder: URL?) -> BoxRan {
            let name = program == swift.path ? "swift" : (program as NSString).lastPathComponent
            lock.withLock { said.append(([name] + arguments).joined(separator: " ")) }
            switch (name, arguments.first ?? "") {
            case ("swift", "sdk") where arguments[1] == "list":
                return BoxRan(status: 0, output: sdk ? "swift-6.4.2-RELEASE_static-linux-0.1.0\n" : "")
            case ("swift", "sdk"):
                sdk = true
                return BoxRan(status: 0)
            case ("swift", "build") where arguments.contains("--show-bin-path"):
                try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: bin.appendingPathComponent("kore-host").path, contents: Data("built".utf8), attributes: [.posixPermissions: 0o755])
                return BoxRan(status: 0, output: bin.path + "\n")
            case ("swift", "build"):
                return buildFails ? BoxRan(status: 1, output: "error: no such module\n") : BoxRan(status: 0, output: "Build complete!\n")
            case ("git", "rev-parse"): return BoxRan(status: 0, output: BoxBuildTests.commit + "\n")
            case ("pkgutil", _): return BoxRan(status: 0, output: "Status: signed\n 1. Developer ID Installer: Swift Open Source (V9AUD2URP3)\n")
            case ("installer", _):
                let swiftly = home.appendingPathComponent(".swiftly/bin/swiftly")
                try? FileManager.default.createDirectory(at: swiftly.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: swiftly.path, contents: Data(), attributes: [.posixPermissions: 0o755])
                return BoxRan(status: 0)
            case ("swiftly", "install"):
                try? addToolchain()
                return BoxRan(status: 0)
            case ("curl", _) where arguments.last?.hasSuffix("releases.json") == true: return BoxRan(status: 0, output: BoxBuildTests.releases)
            default: return BoxRan(status: 0)
            }
        }

        func finish() { try? FileManager.default.removeItem(at: root) }
    }

    nonisolated static let releases = """
        [{"name": "6.4.1", "tag": "swift-6.4.1-RELEASE", "platforms": []},
         {"name": "6.4.2", "tag": "swift-6.4.2-RELEASE", "platforms": [
           {"name": "Ubuntu 24.04", "platform": "Linux"},
           {"name": "Static SDK", "platform": "static-sdk", "version": "0.1.0",
            "checksum": "3786b179936d9cc9e266dd506bd1654176358d7b25288e243359f4d17cc4dc5a", "archs": ["x86_64", "arm64"]}]}]
        """

    final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    // MARK: The kit

    @Test func withTheKitHereALinuxBuildRunsAndIsKept() async throws {
        let box = try Toolbox()
        defer { box.finish() }
        let build = box.build()
        let steps = Steps()
        let got = try await BoxBinary.local(.init(platform: "linux-aarch64") { steps.add($0) }, override: nil, beside: nil, build: build)
        let kept = box.support.appendingPathComponent("kore-host/0.2.3-abcdef1-linux-aarch64")
        #expect(got.url == kept && !got.temporary)
        #expect(try String(contentsOf: kept, encoding: .utf8) == "built")
        let scratch = box.support.appendingPathComponent("kore-host/.build-linux").path
        #expect(box.calls == [
            "swift sdk list", "git rev-parse HEAD",
            "swift build --swift-sdk aarch64-swift-linux-musl -c release --product kore-host --scratch-path \(scratch) -Xlinker --strip-all",
            "swift build --swift-sdk aarch64-swift-linux-musl -c release --product kore-host --scratch-path \(scratch) --show-bin-path",
        ])
        #expect(steps.all == ["Building kore-host for Linux arm64…"])

        // Next time: the cache, nothing run.
        let again = try await BoxBinary.local(.init(platform: "linux-aarch64"), override: nil, beside: nil, build: build)
        #expect(again.url == kept)
        #expect(box.calls.count == 4)
    }

    @Test func withoutTheKitSetUpAsksOnceAndInstallsNothing() async throws {
        let box = try Toolbox(toolchain: false, sdk: false)
        defer { box.finish() }
        let fake = try FakeSSH()
        defer { fake.finish() }
        let build = box.build()
        let setup = BoxSetup(alias: "mybox", grant: "mac", shell: fake.shell) { try await BoxBinary.local($0, override: nil, beside: nil, build: build) }
        await #expect(throws: BoxSetup.Failure(message: "Building kore-host needs Swift's Linux kit (about 2 GB)", fix: .installLinuxKit(update: false))) {
            try await setup.run(allow: true) { _ in }
        }
        await #expect(throws: BoxSetup.Failure(message: BoxSetup.kitLine, fix: .installLinuxKit(update: true))) {
            try await setup.run(allow: false) { _ in }
        }
        #expect(box.calls.isEmpty)
        #expect(!fake.calls.contains { $0.hasPrefix("scp") })
        #expect(BoxFix.installLinuxKit(update: false).title == "Install")
        // A toolchain without its SDK asks the same.
        try box.addToolchain()
        await #expect(throws: BoxSetup.Failure(message: BoxSetup.kitLine, fix: .installLinuxKit(update: false))) {
            try await setup.run(allow: true) { _ in }
        }
        #expect(box.calls == ["swift sdk list"])
    }

    @Test func withConsentTheKitInstallsToTheHomeThenBuilds() async throws {
        let box = try Toolbox(toolchain: false, sdk: false)
        defer { box.finish() }
        let fake = try FakeSSH()
        defer { fake.finish() }
        let build = box.build()
        var setup = BoxSetup(alias: "mybox", grant: "mac", shell: fake.shell) { try await BoxBinary.local($0, override: nil, beside: nil, build: build) }
        setup.mayInstallKit = true
        let steps = Steps()
        try await setup.run(allow: true) { steps.add($0) }
        let pkg = box.support.appendingPathComponent("kore-host/swiftly.pkg").path
        let sdk = "https://download.swift.org/swift-6.4.2-release/static-sdk/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz"
        #expect(Array(box.calls.prefix(10)) == [
            "curl -fsSL -o \(pkg) https://download.swift.org/swiftly/darwin/swiftly.pkg",
            "pkgutil --check-signature \(pkg)",
            "installer -pkg \(pkg) -target CurrentUserHomeDirectory",
            "swiftly init --no-modify-profile --skip-install --quiet-shell-followup --assume-yes",
            "swiftly install 6.4.2 --assume-yes",
            "swift sdk list",
            "curl -fsSL https://www.swift.org/api/v1/install/releases.json",
            "swift sdk install \(sdk) --checksum 3786b179936d9cc9e266dd506bd1654176358d7b25288e243359f4d17cc4dc5a",
            "swift sdk list",
            "git rev-parse HEAD",
        ])
        #expect(box.calls.contains { $0.hasPrefix("swift build --swift-sdk x86_64-swift-linux-musl") })
        #expect(steps.all.prefix(4) == ["Checking mybox…", "Getting kore-host for Linux · x86_64 · Debian GNU/Linux 13 (trixie)…", "Installing Swift's Linux kit…", "Building kore-host for Linux x86_64…"])
        #expect(fake.calls.contains { $0.hasPrefix("scp") })
    }

    @Test func anUnsignedSwiftlyIsNeverInstalled() async throws {
        let box = try Toolbox(toolchain: false, sdk: false)
        defer { box.finish() }
        var build = box.build()
        let answer = build.run
        build.run = { program, arguments, folder, log in
            if program.hasSuffix("pkgutil") { return BoxRan(status: 1, output: "Status: no signature") }
            return await answer(program, arguments, folder, log)
        }
        let log = box.support.appendingPathComponent("kore-host/linux-kit.log").path
        await #expect(throws: BoxSetup.Failure(message: "Couldn't install Swift's Linux kit", fix: .showLog(log))) {
            _ = try await build.build("linux-x86_64", mayInstallKit: true) { _ in }
        }
        #expect(!box.calls.contains { $0.hasPrefix("installer") })
    }

    @Test func theSDKsAddressAndChecksumComeFromSwiftOrg() throws {
        let sdk = try #require(BoxHostBuild.staticSDK(releases: Data(Self.releases.utf8), swift: "6.4.2"))
        #expect(sdk.url == "https://download.swift.org/swift-6.4.2-release/static-sdk/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz")
        #expect(sdk.checksum == "3786b179936d9cc9e266dd506bd1654176358d7b25288e243359f4d17cc4dc5a")
        #expect(BoxHostBuild.staticSDK(releases: Data(Self.releases.utf8), swift: "6.4.1") == nil)
        let bad = Self.releases.replacingOccurrences(of: "3786b179", with: "zz")
        #expect(BoxHostBuild.staticSDK(releases: Data(bad.utf8), swift: "6.4.2") == nil)
    }

    // MARK: Building

    @Test func aFailedBuildSaysSoWithItsLog() async throws {
        let box = try Toolbox()
        defer { box.finish() }
        box.buildFails = true
        let fake = try FakeSSH()
        defer { fake.finish() }
        let build = box.build()
        let setup = BoxSetup(alias: "mybox", grant: "mac", shell: fake.shell) { try await BoxBinary.local($0, override: nil, beside: nil, build: build) }
        let log = box.support.appendingPathComponent("kore-host/0.2.3-abcdef1-linux-x86_64.log").path
        await #expect(throws: BoxSetup.Failure(message: "Couldn't build kore-host", fix: .showLog(log))) {
            try await setup.run(allow: true) { _ in }
        }
        #expect(BoxFix.showLog(log).title == "Show log")
        #expect(!FileManager.default.fileExists(atPath: box.support.appendingPathComponent("kore-host/0.2.3-abcdef1-linux-x86_64").path))
    }

    @Test func aMacBoxBuildsWithTheMacsOwnSwiftAndNoKit() async throws {
        let box = try Toolbox(toolchain: false, sdk: false)
        defer { box.finish() }
        let got = try await BoxBinary.local(.init(platform: "macos-x86_64"), override: nil, beside: nil, build: box.build())
        #expect(got.url.lastPathComponent == "0.2.3-abcdef1-macos-x86_64")
        let scratch = box.support.appendingPathComponent("kore-host/.build-macos").path
        #expect(box.calls == [
            "git rev-parse HEAD",
            "swift build -c release --product kore-host --arch x86_64 --scratch-path \(scratch) -Xlinker -dead_strip",
            "swift build -c release --product kore-host --arch x86_64 --scratch-path \(scratch) --show-bin-path",
        ])
        #expect(BoxHostBuild.name("macos-arm64") == "macOS arm64")
    }

    @Test func withoutItsCheckoutTheSourceIsFetchedAtItsCommitOnce() async throws {
        let box = try Toolbox()
        defer { box.finish() }
        let build = box.build(builtFrom: false)
        let steps = Steps()
        _ = try await build.build("linux-x86_64", mayInstallKit: false) { steps.add($0) }
        #expect(Array(box.calls[1...4]) == [
            "git init -q", "git remote add origin https://github.com/SoumilB7/kore.git",
            "git fetch -q --depth 1 origin \(Self.commit)", "git checkout -q --detach FETCH_HEAD",
        ])
        #expect(steps.all.first == "Getting Kore's source…")
        // Kept: the next build (another CPU) only checks it.
        try FileManager.default.createDirectory(at: box.support.appendingPathComponent("kore-host-src/.git"), withIntermediateDirectories: true)
        let before = box.calls.count
        _ = try await build.build("linux-aarch64", mayInstallKit: false) { _ in }
        #expect(box.calls[before...].filter { $0.hasPrefix("git") } == ["git rev-parse HEAD"])
        // Without a commit, the version's tag.
        let tagged = box.build(commit: nil, builtFrom: false)
        _ = try await tagged.build("linux-x86_64", mayInstallKit: false) { _ in }
        #expect(box.calls.contains("git fetch -q --depth 1 origin refs/tags/v0.2.3"))
    }

    @Test func aNewVersionsBuildPrunesTheOldOnes() async throws {
        let box = try Toolbox()
        defer { box.finish() }
        let folder = box.support.appendingPathComponent("kore-host")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("v0.2.2"), withIntermediateDirectories: true)
        for name in ["0.2.2-1111111-linux-x86_64", "0.2.2-1111111-linux-x86_64.log", "linux-kit.log"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".build-linux"), withIntermediateDirectories: true)
        _ = try await box.build().build("linux-x86_64", mayInstallKit: false) { _ in }
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(left == [".build-linux", "0.2.3-abcdef1-linux-x86_64", "linux-kit.log"])
    }

    // MARK: Where the binary comes from

    @Test func theOverrideThenTheCacheThenTheMacsOwnThenABuild() async throws {
        let box = try Toolbox()
        defer { box.finish() }
        let build = box.build()
        let here = BoxBinary.here
        let beside = box.root.appendingPathComponent("beside")
        try FileManager.default.createDirectory(at: beside, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: beside.appendingPathComponent("kore-host").path, contents: Data("beside".utf8), attributes: [.posixPermissions: 0o755])
        let override = box.root.appendingPathComponent("mine")
        FileManager.default.createFile(atPath: override.path, contents: Data("mine".utf8), attributes: [.posixPermissions: 0o755])
        let cached = build.cachedFile(here)
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cached.path, contents: Data("cached".utf8), attributes: [.posixPermissions: 0o755])

        func from(_ override: String?) async throws -> String {
            let got = try await BoxBinary.local(.init(platform: here), override: override, beside: beside, build: build)
            return try String(contentsOf: got.url, encoding: .utf8)
        }
        #expect(try await from(override.path) == "mine")
        #expect(try await from(nil) == "cached")
        try FileManager.default.removeItem(at: cached)
        #expect(try await from(nil) == "beside")
        #expect(box.calls.isEmpty)
        try FileManager.default.removeItem(at: beside.appendingPathComponent("kore-host"))
        #expect(try await from(nil) == "built")
        // A development run (no version) never takes the cache.
        let dev = box.build(version: nil, commit: nil)
        #expect(dev.cached(here) == nil)
    }

    // MARK: One real build, on purpose only

    /// `KORE_BOX_REAL_BUILD=1`: kore-host for Linux x86_64 from this checkout, with this Mac's
    /// toolchain and SDK as installed (nothing installed or removed), into a scratch cache.
    nonisolated static let realBuild = ProcessInfo.processInfo.environment["KORE_BOX_REAL_BUILD"] != nil

    @Test(.enabled(if: realBuild), .timeLimit(.minutes(30))) func aRealLinuxBuild() async throws {
        let support = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KORE_BOX_REAL_BUILD_CACHE"] ?? NSTemporaryDirectory())
            .appendingPathComponent("boxbuild-real")
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let head = await BoxHostBuild.system("/usr/bin/git", ["rev-parse", "HEAD"], checkout, nil).lastLine
        let build = BoxHostBuild(support: support, version: "0.0.0", commit: head, builtFrom: checkout)
        #expect(await build.kitReady())
        let steps = Steps()
        let got = try await BoxBinary.local(.init(platform: "linux-x86_64") { steps.add($0) }, override: nil, beside: nil, build: build)
        let kind = await BoxHostBuild.system("/usr/bin/file", [got.url.path], nil, nil).output
        #expect(kind.contains("ELF 64-bit") && kind.contains("x86-64") && kind.contains("statically linked"))
        #expect(steps.all.first == "Building kore-host for Linux x86_64…")
        #expect(build.cached("linux-x86_64") == got.url)
    }
}
