import Foundation
import Testing

@testable import KoreCore

/// A CLI started through a trampoline is the same process, with the same pipes, and macOS
/// charges its energy to itself rather than to Kore.
@Suite("Disclaimed CLIs", .serialized)
struct DisclaimTests {
    private final class Marker {}
    private static let trampoline = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent()
        .appendingPathComponent("kore-fake-cli").path

    @Test func withoutATrampolineTheProgramStartsDirectly() {
        Disclaim.trampoline = nil
        #expect(Disclaim.wrap("/bin/cat", ["-u"]) == ("/bin/cat", ["-u"]))
    }

    @Test func aCLIStartedThroughTheTrampolineAnswersAndIsChargedToItself() async throws {
        Disclaim.trampoline = Self.trampoline
        defer { Disclaim.trampoline = nil }
        // `cat` echoes a JSON line back: the pipes reach the program, not the trampoline.
        let io = try StdioProcess(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], cwd: nil, environment: [:])
        try io.write(["ping": 1])
        var echoed: Data?
        for await output in io.output {
            if case .line(let line) = output {
                echoed = line
                break
            }
        }
        #expect(echoed.flatMap { try? JSONValue.parse($0) } == ["ping": 1])
        #expect(Disclaim.responsible(for: io.pid) == io.pid)
        io.close(grace: .milliseconds(100))
        #expect(await io.waitForExit(within: .seconds(2)))
    }
}
