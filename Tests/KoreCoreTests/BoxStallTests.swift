import Foundation
import Testing

@testable import KoreCore

/// What stalled a box's chats (2026-11-11): a clone of a repository whose `.gitignore` names
/// 4,882 paths into a synced folder made every changed path try every rule of every folder above
/// it, once per part of its path. Here: the same shape stays fast and judges as before; the CLI's
/// temp folder is found per platform; a CLI's end reaches its reader and leaves no descriptor.
@Suite("box stall")
struct BoxStallTests {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kore-stall-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("repo"), withIntermediateDirectories: true)
        return root
    }

    @Test func aLongIgnoreFileOverManyPathsStaysFast() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        // As the clone's: thousands of plain paths, a few patterns, a name taken back.
        var lines = (0..<4800).map { ".venv/lib/site-packages/pkg\($0)/out/_next/" }
        lines += ["*.pyc", "build/", "**/cache/*.tmp", "*.log", "!keep.log", "projects/p3/secret.txt"]
        try lines.joined(separator: "\n").write(to: root.appendingPathComponent("repo/.gitignore"), atomically: true, encoding: .utf8)
        let tree = SyncTree(root: root)
        let paths = (0..<15_000).map { "repo/projects/p\($0 % 50)/src/mod\($0 % 300)/deep/file\($0).py" }
        let clock = ContinuousClock()
        let start = clock.now
        let left = paths.filter(tree.ignored).count
        let took = clock.now - start
        #expect(left == 0)
        // Every rule tried per part of each path, as before, took minutes on the box.
        #expect(took < .seconds(2), "took \(took)")

        // The rules still judge as git does: last match wins, plain or pattern, folders above.
        #expect(tree.ignored("repo/.venv/lib/site-packages/pkg7/out/_next/x.js"))
        #expect(tree.ignored("repo/a/b.pyc"))
        #expect(tree.ignored("repo/build/out.bin"))
        #expect(tree.ignored("repo/x/cache/y.tmp"))
        #expect(tree.ignored("repo/debug.log"))
        #expect(!tree.ignored("repo/keep.log"))
        #expect(tree.ignored("repo/projects/p3/secret.txt"))
        #expect(!tree.ignored("repo/projects/p3/public.txt"))
        #expect(!tree.ignored("repo/.venv/lib/site-packages/pkg7/out/next.js"))
        #expect(tree.ignored("repo/.git/config"))

        // A changed `.gitignore` is read again, folders' verdicts with it.
        try "*.py\n".write(to: root.appendingPathComponent("repo/.gitignore"), atomically: true, encoding: .utf8)
        tree.forget("repo/.gitignore")
        #expect(tree.ignored(paths[0]))
        #expect(!tree.ignored("repo/build/out.bin"))
    }

    @Test func theCLIsTempFolder() throws {
        #if canImport(Darwin)
        #expect(ClaudeHistory.tempRoot([:]).path == "/private/tmp")
        #else
        #expect(ClaudeHistory.tempRoot([:]).path == "/tmp")
        #endif
        // TMPDIR isn't the CLI's; CLAUDE_CODE_TMPDIR is.
        #expect(ClaudeHistory.tempRoot(["TMPDIR": "/var/empty"]).path == ClaudeHistory.tempRoot([:]).path)
        let own = try folder()
        defer { try? FileManager.default.removeItem(at: own) }
        let real = realpath(own.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? own.path
        #expect(ClaudeHistory.tempRoot(["CLAUDE_CODE_TMPDIR": own.path]).path == real)
        let file = ClaudeHistory.taskOutput(task: "b1", sessionId: "s1", in: own, environment: ["CLAUDE_CODE_TMPDIR": own.path])
        #expect(file.path.hasPrefix(real + "/claude-\(getuid())/"))
        #expect(file.path.hasSuffix("/s1/tasks/b1.output"))
    }

    @Test func aCLIsEndReachesItsReaderAndLeavesNoDescriptor() async throws {
        var processes: [StdioProcess] = []
        for _ in 0..<12 {
            let io = try StdioProcess(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo hi; echo oops >&2"], cwd: nil,
                environment: ProcessInfo.processInfo.environment)
            var lines: [String] = []
            var status: Int32?
            for await output in io.output {
                switch output {
                case .line(let line): lines.append(String(decoding: line, as: UTF8.self))
                case .exited(let code): status = code
                case .stderr: break
                }
            }
            #expect(lines == ["hi"])
            #expect(status == 0)
            io.close()
            processes.append(io)
        }
        // Each process's two read ends close at EOF, off their handlers' queue. Counted per
        // process, so other suites opening files meanwhile can't move the number.
        var waited = 0
        while processes.contains(where: { $0.readEndsClosed < 2 }), waited < 3000 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 50
        }
        #expect(processes.allSatisfy { $0.readEndsClosed == 2 }, "\(processes.map(\.readEndsClosed))")
    }

}
