import AgentTools
import Foundation
import Testing

/// `kore send`'s arguments: what it always sent for an open chat, `folder` only when given, and
/// the wait for a woken chat's CLI.
@Suite("kore send arguments")
struct KoreSendArgumentsTests {
    final class Recorder: AgentCalls {
        var calls: [(String, AgentTools.Object)] = []
        var waits: [Int] = []
        func run(_ command: String, _ args: AgentTools.Object) throws(AgentFailure) -> AgentTools.Object {
            calls.append((command, args))
            return ["chat": "c", "message": "Sent."]
        }
        func timeout(_ seconds: Int) { waits.append(seconds) }
        func nextRaw() throws(AgentFailure) -> Data? { nil }
    }

    @Test func sendTakesAFolder() {
        let open = Recorder()
        #expect(Reads.run("send", ["work", "hi"], unreachable: "") { open } == 0)
        #expect(open.calls.count == 1 && open.calls[0].0 == "chat.send")
        #expect(open.calls[0].1.keys.sorted() == ["chat", "text"] && open.calls[0].1["chat"] as? String == "work")
        #expect(open.waits == [AgentTools.answerWait("chat.send")] && AgentTools.answerWait("chat.send") == 60)
        let scoped = Recorder()
        #expect(Reads.run("send", ["work", "hi", "--folder", "mybox:~/x"], unreachable: "") { scoped } == 0)
        #expect(scoped.calls[0].1["folder"] as? String == "mybox:~/x")
        // Usage: a chat and a message, one each.
        #expect(Reads.run("send", ["work"], unreachable: "") { Recorder() } == 2)
        #expect(Reads.run("send", ["work", "hi", "--folder"], unreachable: "") { Recorder() } == 2)
        // The tool takes the same, and passes folder through.
        let tool = AgentTools.tool("kore_send")!
        #expect(tool.args.map { $0.0 } == ["chat", "text", "folder"] && tool.required == ["chat", "text"])
        #expect(AgentTools.arguments(tool, ["chat": "x", "text": "y", "folder": "z", "other": 1]).keys.sorted() == ["chat", "folder", "text"])
        #expect(AgentTools.tool("kore_send", box: true)!.args.map { $0.0 } == ["chat", "text", "folder"])
    }
}
