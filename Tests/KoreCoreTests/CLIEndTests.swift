import Foundation
import Testing

@testable import KoreCore

/// kore-host on a box died with SIGILL at a CLI's end (2026-11-11): each pipe's read end was
/// closed from its own readability handler, and on Linux `FileHandle.close()` waits on the queue
/// that handler runs on, which libdispatch traps. Here: CLIs that end, a few at once, and a read
/// end closed from its handler at EOF; the process lives on and the descriptors still close.
@Suite("cli end")
struct CLIEndTests {
    private func openDescriptors() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []).count
    }

    @Test func cLIsEndingAtOnceCloseTheirPipesWithoutTrapping() async throws {
        let before = openDescriptors()
        await withTaskGroup(of: Int32?.self) { group in
            for n in 0..<8 {
                group.addTask {
                    guard
                        let io = try? StdioProcess(
                            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo out\(n); echo err\(n) >&2"], cwd: nil,
                            environment: ProcessInfo.processInfo.environment)
                    else { return nil }
                    var status: Int32?
                    for await output in io.output { if case .exited(let code) = output { status = code } }
                    io.close()
                    return status
                }
            }
            for await status in group { #expect(status == 0) }
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(openDescriptors() <= before + 2, "before \(before), after \(openDescriptors())")
    }

    @Test func aReadEndClosedFromItsOwnHandlerAtEOF() async throws {
        let pipe = Pipe()
        let (ended, end) = AsyncStream<Void>.makeStream()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            guard handle.availableData.isEmpty else { return }
            handle.readabilityHandler = nil
            StdioProcess.closeAfterHandler(handle)
            end.finish()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("x\n".utf8))
        try pipe.fileHandleForWriting.close()
        for await _ in ended {}
        // The close lands once the handler has returned, off its queue.
        try await Task.sleep(for: .milliseconds(100))
    }
}
