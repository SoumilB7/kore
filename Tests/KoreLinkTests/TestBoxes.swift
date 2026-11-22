import Foundation
@testable import KoreHost

/// Boxes made in tests: each its own model lists (two daemons in one process share
/// `ModelCatalog` otherwise), and a `gh` that's never this Mac's own (`FakeGh`).
extension HostDaemon {
    @MainActor static func forTest(paths: HostPaths) -> HostDaemon {
        let host = HostDaemon(paths: paths)
        host.services.modelScope = paths.state.path
        host.sessionEnv["PATH"] = FakeGh.path(host.sessionEnv["PATH"])
        return host
    }
}

/// A `gh` that says "not signed in" and notes each call: a test box never runs the real one
/// (it reads this Mac's GitHub login, over the network).
enum FakeGh {
    static let folder: URL = {
        let folder = URL(fileURLWithPath: "/tmp/kore-fake-gh-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let gh = folder.appendingPathComponent("gh")
        try? Data("#!/bin/sh\necho \"$*\" >> '\(folder.path)/calls'\nexit 1\n".utf8).write(to: gh)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        atexit { _ = try? FileManager.default.removeItem(atPath: "/tmp/kore-fake-gh-\(getpid())") }
        return folder
    }()

    /// `PATH` with the fake first.
    static func path(_ path: String?) -> String { folder.path + ":" + (path ?? "/usr/bin:/bin") }

    /// Each call the fake took, as its arguments.
    static var calls: [String] {
        ((try? String(contentsOf: folder.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}
