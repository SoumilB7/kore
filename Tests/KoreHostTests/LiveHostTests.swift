import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// Checks against real CLIs and a real box, each run on purpose only:
/// - `KORE_HOST_LIVE=1`: one tiny prompt through kore-host to the claude CLI (haiku) and one to
///   codex (gpt-6-luna), on this Mac.
/// - `KORE_HOST_SSH=<host>`: the handshake through `ssh <host> kore-host attach --as laptop`.
@Suite("kore-host, live", .serialized)
@MainActor
struct LiveHostTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["KORE_HOST_LIVE"] == "1"),
        arguments: [("claude", "haiku"), ("codex", "gpt-6-luna")])
    func aRealRoundTrip(_ provider: String, _ model: String) async throws {
        let rig = try HostRig()
        defer { rig.finish() }
        let hc = try #require(rig.host.newChat(folder: rig.folder.path, provider: provider, modelId: model))
        let result = rig.host.apply(.send(chatId: hc.id, text: "Reply with the single word: pong"), id: "1", control: .act) { _ in }
        #expect(result?.ok == true)
        let end = ContinuousClock.now + .seconds(180)
        while !hc.entries.contains(where: { $0.kind == .answer && $0.done }) {
            guard ContinuousClock.now < end else { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let answer = hc.entries.last { $0.kind == .answer }
        print("\(provider)/\(model): \(answer?.text ?? "nothing") · entries \(hc.entries.map(\.kind.rawValue))")
        #expect(answer?.text?.lowercased().contains("pong") == true)
        // What went on the wire is what the log holds.
        rig.restart()
        #expect(rig.host.chat(hc.id)?.entries == hc.entries)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KORE_HOST_SSH"] != nil))
    func handshakeOverSSH() async throws {
        let box = ProcessInfo.processInfo.environment["KORE_HOST_SSH"] ?? ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [box, "~/.local/bin/kore-host", "attach", "--as", "laptop"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        defer { process.terminate() }
        var buffer = Data()
        var frames: [Data] = []
        func next() throws -> LinkMessage {
            while frames.isEmpty {
                let more = output.fileHandleForReading.availableData
                guard !more.isEmpty else { throw Waited.timeout }
                buffer.append(more)
                frames += try LinkFrame.take(&buffer, max: LinkFrame.outboundMax)
            }
            return try LinkMessage.decode(frames.removeFirst())
        }
        guard case .challenge = try next() else { Issue.record("no challenge"); return }
        let hello = try LinkMessage.hello(proto: LinkProto.version, client: .init(name: "probe", build: "1"), proof: "").encoded()
        input.fileHandleForWriting.write(LinkFrame.frame(hello))
        let welcome = try next()
        guard case .welcome(let w) = welcome else { Issue.record("expected welcome, got \(welcome)"); return }
        print("welcome from \(w.host.name): kind \(w.host.kind ?? "-"), proto \(w.proto.major).\(w.proto.minor), control \(w.policy.control?.rawValue ?? "-")")
        #expect(w.host.kind == "box")
        guard case .snapshot(_, let windows, let chats, _) = try next() else { Issue.record("no snapshot"); return }
        print("snapshot: \(windows.count) windows, \(chats.count) chats")
        input.fileHandleForWriting.write(LinkFrame.frame(try LinkMessage.bye(.quit).encoded()))
    }
}
