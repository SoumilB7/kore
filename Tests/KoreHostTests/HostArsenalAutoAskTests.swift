import AgentTools
import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// A box chat's Arsenal on another box chat's "Auto asks" card, answered on the box as a Mac chat's
/// is (the owner, 2026-11-21): run once or Always allowed from Auto with Act unlimited or Act
/// device, never a critical removal, and below Act unlimited `kore_answer` isn't the chat's.
extension HostArsenalTests {
    func autoAsk(_ id: String, _ command: String, rule: String? = nil, folder: String) -> Approval {
        var card = Approval(id: id, title: "Auto asks: \(command) (Kore asks you first.)", detail: nil, body: nil, canAlwaysAllow: rule != nil, questions: [])
        card.autoStop = true
        card.tool = "Bash"
        card.command = command
        card.cwd = folder
        card.alwaysRule = rule
        return card
    }

    @Test func aBoxChatRunsAnAutoAskAsAMacChatDoes() async throws {
        let made = Made()
        let (rig, hc, target) = try rig(made)
        defer { rig.finish() }
        let me = try caller(rig, hc)
        let socket = rig.paths.agentSocket.path
        let short = AgentRefs.short(target.id)
        let mine = try #require(rig.host.live(hc))
        let theirs = try #require(rig.host.live(target))
        let folder = rig.folder.path
        func answer(_ card: String, _ key: String = "allow") async -> (ok: Bool, text: String) {
            await ask("kore_answer", me, socket: socket, ["chat": short, "card": card, key: true])
        }
        func said(_ answer: (ok: Bool, text: String)) -> String { Self.data(answer.text)["message"] as? String ?? answer.text }
        func pending() -> [String] { theirs.approvals.pending.map(\.id) }

        theirs.approvals.apply(.approvalRequested(autoAsk("r-sudo", "sudo reboot", folder: folder)))
        // Below Act unlimited: kore_answer isn't this chat's at all.
        rig.host.arsenalSaid("own", hc)
        mine.setMode("auto", remember: false)
        let own = await answer("r-sudo")
        #expect(!own.ok && own.text.contains("Act unlimited"), "\(own.text)")
        // Below Auto: refused.
        rig.host.arsenalSaid("drive", hc)
        mine.setMode("acceptEdits", remember: false)
        let edits = await answer("r-sudo")
        #expect(!edits.ok && edits.text.contains("Only a chat at Auto or above runs a command Auto asks about"), "\(edits.text)")
        #expect(pending() == ["r-sudo"])
        mine.setMode("auto", remember: false)

        // A critical removal, even at Act device, run once or always.
        rig.host.arsenalSaid("device", hc)
        theirs.approvals.apply(.approvalRequested(autoAsk("r-rm", "rm -rf ~", folder: folder)))
        for key in ["allow", "always"] {
            let rm = await answer("r-rm", key)
            #expect(!rm.ok && rm.text.contains("it removes the working folder or one above it, a home folder or a system path"), "\(key): \(rm.text)")
        }

        // Run once at Act unlimited, then at Act device.
        for (tier, id) in [("drive", "r-sudo"), ("device", "r-sudo2")] {
            rig.host.arsenalSaid(tier, hc)
            if id != "r-sudo" { theirs.approvals.apply(.approvalRequested(autoAsk(id, "sudo reboot", folder: folder))) }
            let ran = await answer(id)
            #expect(ran.ok && said(ran) == "Ran once.", "\(tier): \(ran.text)")
            #expect(!pending().contains(id))
        }
        #expect(theirs.transcriptView.entries.contains { $0.kind == .notice && $0.text.hasPrefix("Arsenal · ran once “sudo reboot” · by ") })

        // Another card's Always stays the person's; an Auto-asks card's keeps the card's rule (after
        // which that chat, told Always allow, is freer than this one and out of its reach).
        theirs.approvals.apply(.approvalRequested(Approval(id: "r-plain", title: "Allow Bash?", detail: nil, body: "ls", canAlwaysAllow: true, questions: [])))
        let plain = await answer("r-plain", "always")
        #expect(!plain.ok && plain.text.contains("Only you choose Always allow here"), "\(plain.text)")
        theirs.approvals.apply(.approvalRequested(autoAsk("r-apt", "sudo apt install cowsay", rule: "sudo apt install *", folder: folder)))
        let always = await answer("r-apt", "always")
        #expect(always.ok && said(always) == "Always allowed `sudo apt install …`.", "\(always.text)")
        #expect(theirs.alwaysAllowed && !pending().contains("r-apt"))
        #expect(theirs.transcriptView.entries.contains { $0.kind == .notice && $0.text.hasPrefix("Arsenal · always allowed “sudo apt install …” · by ") })
        #expect(pending().contains("r-plain") && pending().contains("r-rm"))
    }
}
