import Foundation
import HostClient
import Tailnet
import Testing

/// Kore.app's own `kore-tailnet`: where it's found, and (with `KORE_TAILNET_BIN`, built by
/// scripts/build-tailnet.sh) started with a key and stopped, signed out: it never logs in.
@Suite("kore-tailnet on the Mac")
struct NetSidecarTests {
    nonisolated static let binary = ProcessInfo.processInfo.environment["KORE_TAILNET_BIN"]

    @Test func theHelperIsKoreAppsElseADevBuildsElseNone() throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        func executable(_ path: String) throws -> URL {
            let url = root.appendingPathComponent(path)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        let app = root.appendingPathComponent("Kore.app")
        let exe = root.appendingPathComponent("clone/.build/arm64-apple-macosx/debug/Kore")
        #expect(NetSidecar.helper(bundle: app, executable: exe, environment: [:]) == nil)
        let dev = try executable("clone/build/release/kore-tailnet-macos-arm64")
        #expect(NetSidecar.helper(bundle: app, executable: exe, environment: [:])?.path == dev.path)
        let set = try executable("elsewhere/kore-tailnet")
        #expect(NetSidecar.helper(bundle: app, executable: exe, environment: ["KORE_TAILNET_BIN": set.path])?.path == set.path)
        let shipped = try executable("Kore.app/Contents/Helpers/kore-tailnet")
        #expect(NetSidecar.helper(bundle: app, executable: exe, environment: ["KORE_TAILNET_BIN": set.path])?.path == shipped.path)
    }

    @Test(.enabled(if: binary != nil)) func startsWithItsKeyAndStops() throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let sidecar = try NetSidecar.start(helper: URL(fileURLWithPath: try #require(Self.binary)), folder: root.appendingPathComponent("t"), key: key)
        let state = try sidecar.tailnet.status().backendState
        #expect([.noState, .needsLogin, .starting].contains(state))
        sidecar.stop()
        let end = Date().addingTimeInterval(5)
        while sidecar.running, Date() < end { usleep(20_000) }
        #expect(!sidecar.running)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("t/kt.sock").path))
        // The state on disk is sealed: a wrong key is refused.
        #expect(throws: (any Error).self) { try NetSidecar.start(helper: URL(fileURLWithPath: Self.binary!), folder: root.appendingPathComponent("t"), key: Data(repeating: 1, count: 32)) }
    }
}
