import AppKit
import Foundation
import HostClient
import KoreUI
import LinkProtocol

// A box's workbook and PDF open as on this Mac: Quick Look and the PDF view, from a copy the Mac
// fetched over the link (`fs.read {offset}`), never "This file is binary". The renderers don't
// depend on the chat's CLI: a box window's file tabs are the same for Claude and Codex.

/// A scripted box serves a tiny .xlsx and a .pdf; each opens from the explorer's path in its
/// renderer, and the workbook's Quick Look view is in the window.
final class BoxFilePreviews: Storyline {
    override class var tags: Set<Tag> { [.gate] }

    override func steps() -> [any Step] {
        let box = { (story: StoryContext) in story.stash(ScriptedFilesBox.self) { ScriptedFilesBox(story) } }
        let sheet = ScriptedFilesBox.folder + "/circulars 40-49.xlsx"
        let pdf = ScriptedFilesBox.folder + "/report.pdf"
        return [
            BoxStep("Open the box folder's window, linked") { try await box($0).open($0) },
            Do("Open the box's workbook") { story in try box(story).workspace().storyOpenBoxFile(sheet) },
            Expect("Quick Look shows it, not binary", found: { try? box($0).workspace().storyBoxFileState }) { story in
                let workspace = try box(story).workspace()
                return workspace.storyBoxFileState == "quicklook" && workspace.storyShowsQuickLook
            },
            Expect("its bytes asked in pieces, nothing written", found: { box($0).asked.joined(separator: " ") }) { story in
                let asked = box(story).asked
                return asked.contains("fs.read@0 " + sheet) && !asked.contains { $0.hasPrefix("fs.write") }
            },
            Do("Open the box's PDF") { story in try box(story).workspace().storyOpenBoxFile(pdf) },
            Expect("the PDF view shows it", found: { try? box($0).workspace().storyBoxFileState }) { story in
                try box(story).workspace().storyBoxFileState == "pdf"
            },
        ]
    }
}

/// A box for one storyline: answers each dial's hello with a welcome that says `fsBytes` and a
/// snapshot of one empty folder window, and its `fs.*` commands from the files it holds.
@MainActor
final class ScriptedFilesBox: StoryFinishing {
    /// Not a box the other storylines name.
    let alias = "filebox"
    static let folder = "/home/me/saarthi"
    /// The commands it was sent: "fs.read@<offset> <path>", "fs.list <path>"…
    private(set) var asked: [String] = []
    let connection: HostConnection
    private var files: [String: Data] = [:]
    private var transport: PipeTransport?
    private var pump: Task<Void, Never>?

    init(_ story: StoryContext) {
        let cache = HostCache(alias: alias, root: story.outputs.appendingPathComponent("box-\(story.name)", isDirectory: true))
        weak var box: ScriptedFilesBox?
        connection = HostConnection(alias: alias, cache: cache) { box?.dial() ?? PipeTransport(input: .nullDevice, output: .nullDevice) }
        box = self
        HostConnection.adopt(connection)
        files[Self.folder + "/circulars 40-49.xlsx"] = Data(base64Encoded: Self.sheet) ?? Data()
        files[Self.folder + "/report.pdf"] = Self.pdf()
    }

    func open(_ story: StoryContext) async throws {
        guard let model = AppModel.shared else { throw StoryFailure.other("the app model isn't up") }
        model.storyOpenBox(alias: alias, folder: Self.folder)
        let window = try await story.wait("the box window, linked") { () -> NSWindow? in
            guard let workspace = try? self.workspace(), self.connection.isOnline else { return nil }
            return workspace.window
        }
        window.setContentSize(story.windowSize)
        try await story.idle()
    }

    func workspace() throws -> Workspace {
        guard let workspace = Workspace.all.allObjects.first(where: { !$0.isClosed && $0.boxAlias == alias }) else {
            throw StoryFailure.modelMissing("the box window")
        }
        return workspace
    }

    private func send(_ message: LinkMessage) { transport?.send((try? message.encoded()) ?? Data()) }

    private func send(_ result: FilesResult) { transport?.send((try? JSONEncoder().encode(result)) ?? Data()) }

    /// A dial: a new pipe pair, the box's end answering the hello and the commands.
    private func dial() -> any HostTransport {
        let toHost = Pipe(), toMac = Pipe()
        let mac = PipeTransport(input: toMac.fileHandleForReading, output: toHost.fileHandleForWriting)
        let end = PipeTransport(input: toHost.fileHandleForReading, output: toMac.fileHandleForWriting)
        try? end.start()
        pump?.cancel()
        transport = end
        pump = Task { [weak self] in
            for await event in end.events {
                guard case .frame(let data) = event, let self, self.transport === end else { continue }
                self.arrived(data)
            }
        }
        end.send((try? LinkMessage.challenge(nonce: "bm9uY2U=").encoded()) ?? Data())
        return mac
    }

    private func arrived(_ data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let type = object["t"] as? String else { return }
        if type == "hello" {
            send(.welcome(.init(
                proto: LinkVersion(major: LinkProto.major, minor: LinkProto.boxMinor), epoch: "e1",
                host: .init(name: alias, koreVersion: "1", kind: "box"), providers: [],
                policy: .init(sendMaxLevel: .danger, control: .full),
                caps: ["tx", "attn", "commands", "control", "box", LinkFiles.bytesCap])))
            let window = LinkWindow(id: BoxFolder.windowId(Self.folder), name: "saarthi", path: "~/saarthi", tabs: [], activeTabId: nil)
            send(.snapshot(rev: 1, windows: [window], chats: []))
            return
        }
        guard type == "cmd", let id = object["id"] as? String, let cmd = object["cmd"] as? [String: Any], let kind = cmd["type"] as? String else { return }
        let path = cmd["path"] as? String ?? ""
        switch kind {
        case "fs.list":
            asked.append("fs.list " + path)
            let entries = files.keys.filter { ($0 as NSString).deletingLastPathComponent == path }.sorted()
                .map { FileEntry(name: ($0 as NSString).lastPathComponent, kind: .file, size: Int64(files[$0]?.count ?? 0)) }
            send(FilesResult(id: id, ok: true, path: path, entries: entries, more: false))
        case "fs.watch":
            asked.append("fs.watch")
            send(FilesResult(id: id, ok: true, watching: true))
        case "fs.read":
            let offset = (cmd["offset"] as? Int).map(Int64.init)
            asked.append("fs.read\(offset.map { "@\($0)" } ?? "") " + path)
            guard let bytes = files[path] else { return send(FilesResult.refused(id, .goneFile, "Not there on this box.")) }
            let size = Int64(bytes.count)
            if let base = cmd["base"] as? [String: Any], base["size"] as? Int == bytes.count, base["mtime"] as? Int == 5 {
                return send(FilesResult(id: id, ok: true, path: path, size: size, mtime: 5, unchanged: true))
            }
            if let offset {
                let piece = bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + LinkFiles.pieceMax))
                return send(FilesResult(id: id, ok: true, path: path, kind: .binary, size: size, data: piece.base64EncodedString(), mtime: 5))
            }
            // As kore-host reads: a NUL near the start is binary, else text as best it decodes.
            if bytes.prefix(8192).contains(0) { return send(FilesResult(id: id, ok: true, path: path, kind: .binary, size: size, mtime: 5)) }
            send(FilesResult(id: id, ok: true, path: path, kind: .text, size: size, text: String(decoding: bytes, as: UTF8.self), mtime: 5))
        default:
            asked.append(kind)
            send(FilesResult(id: id, ok: false, code: .invalid, message: LinkPolicy.unknownCommand))
        }
    }

    /// A one-page PDF, drawn here.
    static func pdf() -> Data {
        let data = NSMutableData()
        var page = CGRect(x: 0, y: 0, width: 300, height: 200)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { return Data() }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 40, y: 40, width: 220, height: 120))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// A one-sheet workbook ("Circular | Topic", "40 | Fees"), 1.6 KB.
    static let sheet = "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"

    func finish() {
        (try? workspace())?.window?.close()
        pump?.cancel()
        transport = nil
    }
}
