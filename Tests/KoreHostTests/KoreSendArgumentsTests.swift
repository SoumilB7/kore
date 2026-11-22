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
        #expect(tool.args.map { $0.0 } == ["chat", "text", "folder", "silent"] && tool.required == ["chat", "text"])
        #expect(AgentTools.arguments(tool, ["chat": "x", "text": "y", "folder": "z", "other": 1]).keys.sorted() == ["chat", "folder", "text"])
        #expect(AgentTools.tool("kore_send", box: true)!.args.map { $0.0 } == ["chat", "text", "folder", "silent"])
    }

    /// `kore new --folder F --silent`, `kore open --silent` and `kore send --silent`: each sent only
    /// when given; without them, what each sent before.
    @Test func newOpenAndSendTakeSilentAndNewAFolder() {
        let plain = Recorder()
        #expect(Reads.run("new", ["hi"], unreachable: "") { plain } == 0)
        #expect(plain.calls[0].0 == "chat.new" && plain.calls[0].1.keys.sorted() == ["text"])
        let folder = Recorder()
        #expect(Reads.run("new", ["--folder", "~/work", "--codex", "--silent", "hi"], unreachable: "") { folder } == 0)
        let args = folder.calls[0].1
        #expect(args.keys.sorted() == ["folder", "provider", "silent", "text"])
        #expect(args["folder"] as? String == "~/work" && args["silent"] as? Bool == true && args["text"] as? String == "hi")
        let open = Recorder()
        #expect(Reads.run("open", ["abc123", "--silent"], unreachable: "") { open } == 0)
        #expect(open.calls[0].0 == "chat.open" && open.calls[0].1["silent"] as? Bool == true)
        let opened = Recorder()
        #expect(Reads.run("open", ["abc123"], unreachable: "") { opened } == 0)
        #expect(opened.calls[0].1.keys.sorted() == ["session"])
        let send = Recorder()
        #expect(Reads.run("send", ["work", "hi", "--silent"], unreachable: "") { send } == 0)
        #expect(send.calls[0].1["silent"] as? Bool == true)
        // Usage: --folder takes a folder; still one message at most.
        #expect(Reads.run("new", ["--folder"], unreachable: "") { Recorder() } == 2)
        #expect(Reads.run("new", ["--silent", "a", "b"], unreachable: "") { Recorder() } == 2)
        // The tools take the same.
        #expect(AgentTools.tool("kore_new_chat")!.args.map { $0.0 } == ["provider", "model", "mode", "text", "folder", "silent"])
        #expect(AgentTools.tool("kore_new_chat", box: true)!.args.map { $0.0 } == ["provider", "model", "mode", "text", "folder", "silent", "place"])
        #expect(AgentTools.tool("kore_open_chat")!.args.map { $0.0 } == ["session", "folder", "silent"])
        #expect(Reads.usage.contains("kore new [--claude|--codex] [--model M] [--mode X] [--folder F] [--silent]"))
    }
}
