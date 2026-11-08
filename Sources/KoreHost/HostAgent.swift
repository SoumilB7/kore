import AgentTools
import Foundation
import KoreCore
import LinkProtocol
import src

// Link 1.6, Arsenal on a box (`docs/link-1.4-box.md`): a box chat's agent uses Kore's `kore_app`
// tools. kore-host gives every chat's CLI its own MCP server, `kore-host mcp`; each call comes to
// the daemon on `agent.sock` with the chat's id and the secret its CLI was started with. A call
// about the box's own chats kore-host answers itself (`HostArsenal`), by the tier the Mac last said;
// the rest goes on to the Mac as `agent.call`, which decides and answers (`agent.result`). Idle,
// this is one more listening socket.

/// A call passed to the Mac, waiting for its answer.
struct HostToolCall {
    weak var client: LinkClient?
    let chatId: String
    /// The call, for the box to answer itself when the Mac has no tab of the chat.
    let tool: String
    let given: AgentTools.Object
    let socket: HostSocket
    let timer: DispatchWorkItem
}

extension HostDaemon {
    /// Calls being asked at once (each one `kore-host mcp` connection).
    static let askersMax = 16

    /// The `kore_app` server, given to every chat's CLI as the Mac gives its own: each tool call
    /// goes to the Mac, which answers it under the chat's tier there (off: refused, saying how to
    /// turn it on). A tier that changes needs no new CLI, so a chat that's always working (a long
    /// turn, a background command) has its tools the moment Arsenal is turned on.
    func server(for chat: Chat) -> KoreReach.Server? {
        guard let hc = chats.first(where: { $0.chat === chat }) else { return nil }
        hc.serverGiven = true
        return KoreReach.Server(
            command: mcpCommand, arguments: ["mcp"], pathFolder: koreFolder(), instructions: HostServices.toolInstructions,
            variables: ["KORE_AGENT_SOCKET": paths.agentSocket.path, KoreReach.chatVariable: hc.id], approved: true)
    }

    /// `kore` for a box chat's shell, as a Mac chat has it (`HostCommand`): a folder in the runtime
    /// one holding a link named `kore` to this binary, for the front of the CLI's PATH. Made again
    /// when the binary moved; nil when it can't be made.
    func koreFolder() -> String? {
        let folder = paths.runtime.appendingPathComponent("bin", isDirectory: true)
        let link = folder.appendingPathComponent("kore")
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == mcpCommand.path { return folder.path }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if (try? fm.attributesOfItem(atPath: link.path)) != nil { try fm.removeItem(at: link) }
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: mcpCommand.path)
            return folder.path
        } catch {
            HostJournal.note("kore link failed", ["reason": "\(error)"])
            return nil
        }
    }

    /// The chat's tier on the Mac, said with a message, a follow or a change there: kept in its
    /// record, for its meta, its notes and the calls the box answers itself while the Mac is away.
    /// Its CLI has the server whatever the tier (`server(for:)`), so nothing starts again.
    func arsenalSaid(_ tier: String?, _ hc: HostChat) {
        hc.arsenal = tier.flatMap { BoxTools.tiers.contains($0) ? $0 : nil }
    }

    // MARK: agent.sock

    func openAgentSocket() {
        do {
            agentListener = try HostListener(path: paths.agentSocket) { [weak self] socket in self?.asking(socket) }
        } catch {
            HostJournal.note("agent socket failed", ["reason": "\(error)"])
        }
    }

    /// Held until the asker closes it, which it does once it has its answer.
    private func asking(_ socket: HostSocket) {
        guard askers.count < Self.askersMax else { return socket.close() }
        let key = ObjectIdentifier(socket)
        askers[key] = (socket, false)
        socket.start(
            max: LinkFrame.inboundMax,
            frame: { [weak self] data in
                guard let self, let asker = self.askers[key], !asker.asked else { return }
                self.askers[key]?.asked = true
                self.ask(data, asker.socket)
            },
            ended: { [weak self] in
                guard let self else { return }
                self.askers[key] = nil
                for (id, call) in self.toolCalls where ObjectIdentifier(call.socket) == key {
                    call.timer.cancel()
                    self.toolCalls[id] = nil
                }
            })
    }

    /// One call: from a chat's own CLI, by the secret kore-host gave it, to a connected Mac.
    private func ask(_ data: Data, _ socket: HostSocket) {
        func reply(_ text: String) { socket.send(BoxTools.encode(BoxToolResult(id: "", ok: false, text: text))) }
        guard let ask = try? JSONDecoder().decode(BoxToolAsk.self, from: data), ask.t == BoxToolAsk.type else { return reply("Not a tool call.") }
        guard let hc = chat(ask.chatId), let pass = hc.chat?.agentPass, Self.same(pass, ask.pass) else {
            HostJournal.note("tool refused", ["reason": "pass"])
            return reply("This process isn't one of kore-host's chats.")
        }
        // As many at once as a chat on the Mac holds (`AgentTools.callsAtOnce`), here and at the Mac.
        let held = (boxArsenal.inFlight[hc.id] ?? 0) + toolCalls.values.filter { $0.chatId == hc.id }.count
        guard held < AgentTools.callsAtOnce else {
            socket.send(BoxTools.encode(BoxToolResult(id: "", ok: false, code: AgentCode.rateLimited.rawValue, text: AgentTools.tooManyLine)))
            return
        }
        let given = (try? ask.args?.encoded()).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? AgentTools.Object ?? [:]
        let client = toolClient(hc)
        if answersHere(hc, ask.tool, given, mac: client != nil) { return answerHere(hc, ask.tool, given, socket) }
        guard let client else { return reply(Self.notConnected) }
        toolSerial += 1
        let id = "a\(toolSerial)"
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.answer(id, BoxToolResult(id: "", ok: false, text: AgentTools.noAnswerLine)) }
        }
        toolCalls[id] = HostToolCall(client: client, chatId: hc.id, tool: ask.tool, given: given, socket: socket, timer: timer)
        client.sendRaw(BoxTools.encode(BoxToolCall(id: id, chatId: hc.id, tool: ask.tool, args: ask.args)))
        DispatchQueue.main.asyncAfter(deadline: .now() + HostToolServer.wait(ask.tool, ask.args), execute: timer)
    }

    /// One call the box answers itself (`HostArsenal`), on the asker's socket.
    private func answerHere(_ hc: HostChat, _ tool: String, _ given: AgentTools.Object, _ socket: HostSocket) {
        boxArsenal.inFlight[hc.id, default: 0] += 1
        Task { [weak self] in
            guard let self else { return }
            let line = await self.arsenalCall(hc, tool, given)
            self.boxArsenal.inFlight[hc.id, default: 1] -= 1
            socket.send(BoxTools.encode(ArsenalRules.result(line, id: "")))
        }
    }

    /// The Mac's refusal when it has no tab of the chat (its window there is closed): a call the
    /// box can answer is answered here instead.
    static let noTabLine = "That chat isn't open in Kore on the Mac."

    /// The Mac that follows the chat, else the last full grant to connect.
    private func toolClient(_ hc: HostChat) -> LinkClient? {
        let full = fullClients
        return full.last { $0.streams(hc.id) } ?? full.last
    }

    /// The Mac's answer: only from the connection the call went to.
    func toolAnswered(_ data: Data, from client: LinkClient) {
        guard let result = try? JSONDecoder().decode(BoxToolResult.self, from: data), let call = toolCalls[result.id], call.client === client else { return }
        if !result.ok, result.code == AgentCode.noChat.rawValue, result.text == Self.noTabLine, let hc = chat(call.chatId),
            answersHere(hc, call.tool, call.given, mac: false)
        {
            toolCalls[result.id] = nil
            call.timer.cancel()
            return answerHere(hc, call.tool, call.given, call.socket)
        }
        answer(result.id, BoxToolResult(id: "", ok: result.ok, code: result.code, text: result.text))
    }

    /// A Mac's connection ended: its calls are answered so.
    func toolCallsEnded(_ client: LinkClient) {
        for (id, call) in toolCalls where call.client === client || call.client == nil {
            answer(id, BoxToolResult(id: "", ok: false, text: Self.notConnected))
        }
    }

    private func answer(_ id: String, _ result: BoxToolResult) {
        guard let call = toolCalls.removeValue(forKey: id) else { return }
        call.timer.cancel()
        call.socket.send(BoxTools.encode(result))
    }

    static var notConnected: String { "Kore isn't connected to \(ProcessInfo.processInfo.hostName) right now." }

    /// Compared in constant time.
    static func same(_ a: String, _ b: String) -> Bool {
        let (x, y) = (Array(a.utf8), Array(b.utf8))
        guard x.count == y.count, !x.isEmpty else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
