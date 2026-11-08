import AgentTools
import Foundation
import KoreCore
import LinkProtocol
import src

// Link 1.6, Arsenal on a box (`docs/link-1.4-box.md`): a box chat's agent uses Kore's `kore_app`
// tools on the Mac. kore-host gives a chat whose Arsenal is on (as the Mac says with each message)
// its own MCP server, `kore-host mcp`; each call comes to the daemon on `agent.sock` with the chat's
// id and the secret its CLI was started with, and goes on to the Mac as `agent.call`. The Mac
// decides and answers (`agent.result`); kore-host only passes calls on. Idle, this is one more
// listening socket.

/// A call passed to the Mac, waiting for its answer.
struct HostToolCall {
    weak var client: LinkClient?
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
            command: mcpCommand, arguments: ["mcp"], pathFolder: nil, instructions: HostServices.toolInstructions,
            variables: ["KORE_AGENT_SOCKET": paths.agentSocket.path, KoreReach.chatVariable: hc.id], approved: true)
    }

    /// The chat's tier on the Mac, said with a message, a follow or a change there: kept, for its
    /// meta and its notes. Its CLI has the server whatever the tier (`server(for:)`), so nothing
    /// starts again.
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
        guard let client = toolClient(hc) else { return reply(Self.notConnected) }
        toolSerial += 1
        let id = "a\(toolSerial)"
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.answer(id, BoxToolResult(id: "", ok: false, text: AgentTools.noAnswerLine)) }
        }
        toolCalls[id] = HostToolCall(client: client, socket: socket, timer: timer)
        client.sendRaw(BoxTools.encode(BoxToolCall(id: id, chatId: hc.id, tool: ask.tool, args: ask.args)))
        DispatchQueue.main.asyncAfter(deadline: .now() + HostToolServer.wait(ask.tool, ask.args), execute: timer)
    }

    /// The Mac that follows the chat, else the last full grant to connect.
    private func toolClient(_ hc: HostChat) -> LinkClient? {
        let full = fullClients
        return full.last { $0.streams(hc.id) } ?? full.last
    }

    /// The Mac's answer: only from the connection the call went to.
    func toolAnswered(_ data: Data, from client: LinkClient) {
        guard let result = try? JSONDecoder().decode(BoxToolResult.self, from: data), toolCalls[result.id]?.client === client else { return }
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
