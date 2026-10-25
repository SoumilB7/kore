import Darwin
import Foundation
import Testing

@testable import KoreCore

@Suite("owned process trees", .serialized)
struct ProcessChildTests {
    @Test func enumeratesManyChildrenWithoutTruncatingOrSignallingThem() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("process-tree-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("ready")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "i=0; while [ \"$i\" -lt 64 ]; do /bin/sleep 30 & i=$((i+1)); done; : > \"$OWNED_TEST_MARKER\"; wait"]
        process.environment = ["PATH": "/usr/bin:/bin", "OWNED_TEST_MARKER": marker.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let root = try #require(ProcessChild(process.processIdentifier))
        defer { root.close(immediately: true); process.waitUntilExit() }
        let readyBy = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < readyBy {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let children = root.descendants()
        #expect(children.count == 64)
        #expect(!children.contains(root))
        #expect(children.allSatisfy { $0.alive })
        root.close(immediately: true)
        let endedBy = Date().addingTimeInterval(2)
        while children.contains(where: { $0.alive }), Date() < endedBy {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(children.allSatisfy { !$0.alive })
    }
}
