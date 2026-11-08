import Foundation
import LinkProtocol

// Link 1.8's terminals and git, as one client's link reads them (`LinkBoxAsk.swift`): each
// checked by `LinkPolicy.checkBox` against the grant as its file says now, then run where the
// box keeps them (`HostTerminals`, `HostGit`).
extension LinkClient {
    func boxAsk(_ type: String, _ data: Data) {
        guard let ask = BoxAsk.decode(type: type, data) else {
            if let id = StreamWire.id(data) { sendRaw(StreamWire.encode(PtyResult.refused(id, .invalid, "That message isn't one this box reads."))) }
            return
        }
        guard let grant = current() else { return }
        if case .deny(let code, let message) = LinkPolicy.checkBox(ask, control: grant.control == .full ? .full : .standard) {
            if let id = ask.id { sendRaw(StreamWire.encode(PtyResult.refused(id, code, message))) }
            return
        }
        let served = host.config.folders
        switch ask {
        case .ptyOpen(let open):
            sendRaw(StreamWire.encode(host.terminals.open(open, grant: grant.name, client: self, served: served)))
        case .ptyAttach(let attach):
            let result = host.terminals.attach(attach, grant: grant.name, client: self)
            if !result.ok { sendRaw(StreamWire.encode(result)) }
        case .ptyInput(let input):
            host.terminals.input(input, grant: grant.name)
        case .ptyResize(let resize):
            host.terminals.resize(resize, grant: grant.name)
        case .ptyClose(let close):
            host.terminals.close(close, grant: grant.name)
        case .gitStatus(let status):
            Task { [weak self] in
                guard let self else { return }
                let result = await self.host.git.status(status, client: self, served: served)
                self.sendRaw(StreamWire.encode(result))
            }
        case .gitUnwatch(let unwatch):
            host.git.unwatch(root: unwatch.root, client: self)
        case .gitDiff(let diff):
            Task { [weak self] in
                guard let self else { return }
                self.sendRaw(StreamWire.encode(await self.host.git.diff(diff, served: served)))
            }
        case .gitLineChanges(let ask):
            Task { [weak self] in
                guard let self else { return }
                self.sendRaw(StreamWire.encode(await self.host.git.lineChanges(ask, served: served)))
            }
        }
    }

    /// The link went: its shells wait for the next, its git watches end.
    func boxAsksEnded() {
        host.terminals.detach(self)
        host.git.ended(self)
    }
}
