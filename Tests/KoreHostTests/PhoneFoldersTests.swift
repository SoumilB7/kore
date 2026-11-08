import Foundation
import Testing

@testable import KoreHost
@testable import LinkProtocol

/// A phone's folder browser on a box (an act grant): subfolders of the home only, a new folder
/// made there, and Open here adding it as a window; a phone never through a hidden name or out of
/// the home, while a Mac's grant adds any folder as before.
@Suite("kore-host phone folders", .serialized)
@MainActor
struct PhoneFoldersTests {
    @Test func thePolicyKeepsAPhoneInTheHomeAndOutOfHiddenFolders() {
        let home = "/home/u"
        func check(_ kind: ControlKind, _ path: String?, hidden: Bool? = nil) -> LinkPolicy.Verdict {
            LinkPolicy.checkHomeFolders(kind, ControlArgs(path: path, hidden: hidden), home: home)
        }
        #expect(check(.fsList, nil) == .allow)
        #expect(check(.fsList, "/home/u") == .allow)
        #expect(check(.fsList, "/home/u/Code/app/") == .allow)
        #expect(check(.fsMkdir, "/home/u/Code/new") == .allow)
        #expect(check(.folderAdd, "/home/u/Code/new") == .allow)
        // Out of the home, `..` included, or a prefix that only looks like it.
        for path in ["/etc", "/home", "/home/u/../v", "/home/uu/x", "/"] {
            #expect(check(.fsList, path) == .deny(.deniedPath, "Only folders in your home on the box."), "\(path)")
            #expect(check(.folderAdd, path) == .deny(.deniedPath, "Only folders in your home on the box."), "\(path)")
        }
        // Hidden on the way, asked for, or made.
        #expect(check(.fsList, "/home/u/.ssh") == .deny(.deniedPath, LinkPolicy.hiddenRefused))
        #expect(check(.fsList, nil, hidden: true) == .deny(.deniedPath, LinkPolicy.hiddenRefused))
        #expect(check(.fsMkdir, "/home/u/Code/.hide") == .deny(.deniedPath, LinkPolicy.hiddenRefused))
        #expect(check(.folderAdd, "/home/u/.config/app") == .deny(.deniedPath, LinkPolicy.hiddenRefused))
        // Not a path, the home itself made, a name too long, or any other file command.
        #expect(check(.fsMkdir, "relative") == .deny(.invalid, "An absolute path."))
        #expect(check(.folderAdd, nil) == .deny(.invalid, "An absolute path."))
        #expect(check(.fsMkdir, "/home/u") == .deny(.invalid, "Name the new folder."))
        #expect(check(.fsMkdir, "/home/u/" + String(repeating: "a", count: 256)) == .deny(.invalid, "Name the new folder."))
        for kind in [ControlKind.fsRead, .fsWrite, .fsDelete, .fsRename, .fsCreate, .syncApply] {
            #expect(check(kind, "/home/u/a") == .deny(.deniedControl, "That needs a grant with full control."), "\(kind)")
        }
    }

    @Test func theBrowserListsSubfoldersOnlyAndNoLinkOutOfTheHome() throws {
        let root = "/tmp/khp-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let home = root + "/home"
        for folder in [home + "/Code/app", home + "/.ssh", home + "/notes", root + "/secret"] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: home + "/todo.txt", contents: Data("x".utf8))
        try FileManager.default.createSymbolicLink(atPath: home + "/app", withDestinationPath: home + "/Code/app")
        try FileManager.default.createSymbolicLink(atPath: home + "/out", withDestinationPath: root + "/secret")
        let files = HostFiles(home: home, served: [])
        let top = files.folders(id: "1", path: nil)
        #expect(top.path == home)
        #expect(top.entries?.map(\.name) == ["app", "Code", "notes"])
        #expect(files.folders(id: "2", path: home + "/Code").entries?.map(\.name) == ["app"])
        #expect(files.folders(id: "3", path: home + "/out").code == .deniedPath)
        #expect(files.folders(id: "4", path: root + "/secret").code == .deniedPath)
    }

    @Test func aPhoneMakesAFolderAndOpensItAsAWindowAudited() async throws {
        let rig = try HostRig()
        defer { rig.finish() }
        let journal = JournalLines()
        defer { journal.stop() }
        let home = rig.root.path
        rig.host.sessionEnv["HOME"] = home
        try FileManager.default.createDirectory(atPath: home + "/Code", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.config", withIntermediateDirectories: true)
        try rig.host.start()
        let grant = try GrantStore(rig.paths.grants).allow("phone", control: .act, socket: rig.paths.socket)
        let client = try Client(rig.paths.socket)
        try await until { !client.got.isEmpty }
        client.hello(grant: grant)
        try await until { client.got.count >= 3 }
        client.socket.send(.cmd(id: "m", .control(.fsMkdir, ControlArgs(path: home + "/Code/fresh"))))
        client.socket.send(.cmd(id: "h", .control(.fsMkdir, ControlArgs(path: home + "/Code/.fresh"))))
        client.socket.send(.cmd(id: "o", .control(.fsMkdir, ControlArgs(path: "/tmp/kh-phone-\(UUID().uuidString.prefix(6))"))))
        try await until { client.raws.compactMap(Self.files).count >= 3 }
        let made = Dictionary(client.raws.compactMap(Self.files).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(made["m"]?.ok == true)
        #expect(made["m"]?.path == home + "/Code/fresh")
        #expect(made["h"]?.code == .deniedPath)
        #expect(made["o"]?.code == .deniedPath)
        #expect(!FileManager.default.fileExists(atPath: home + "/Code/.fresh"))
        #expect(journal.lines.contains { $0.hasPrefix("audit mkdir") && $0.contains("path=\(home)/Code/fresh") && $0.contains("ok=1") })
        // Open here: the folder is served, its window comes back by id, audited with who and how.
        client.socket.send(.cmd(id: "a", .control(.folderAdd, ControlArgs(path: home + "/Code/fresh"))))
        try await until { client.got.contains { if case .result(let r) = $0 { r.id == "a" } else { false } } }
        let added = client.got.compactMap { if case .result(let r) = $0, r.id == "a" { r } else { nil } }.first
        #expect(added?.ok == true)
        #expect(added?.windowId == HostDaemon.windowID(home + "/Code/fresh"))
        #expect(rig.host.config.folders.contains(home + "/Code/fresh"))
        #expect(rig.host.windows.contains { $0.id == HostDaemon.windowID(home + "/Code/fresh") })
        #expect(journal.lines.contains { $0.hasPrefix("audit folder add") && $0.contains("control=act") && $0.contains("ok=1") })
    }

    @Test func aPhonesAddStaysInTheHomeAndAMacsGrantAddsAny() throws {
        let rig = try HostRig()
        defer { rig.finish() }
        let home = rig.root.path + "/home"
        rig.host.sessionEnv["HOME"] = home
        for folder in [home + "/app", home + "/.config", rig.root.path + "/srv"] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(atPath: home + "/out", withDestinationPath: rig.root.path + "/srv")
        func add(_ path: String, _ control: GrantControl, phone: Bool) -> LinkMessage.Result? {
            rig.host.apply(.control(.folderAdd, ControlArgs(path: path)), id: "x", control: control, phone: phone) { _ in }
        }
        // A phone: inside the home only, never hidden, never through a link out of it.
        #expect(add(home + "/app", .act, phone: true)?.windowId == HostDaemon.windowID(home + "/app"))
        #expect(add(home + "/.config", .act, phone: true)?.code == .deniedPath)
        #expect(add(home + "/out", .act, phone: true)?.code == .deniedPath)
        #expect(add(rig.root.path + "/srv", .act, phone: true)?.code == .deniedPath)
        #expect(add("~/app", .act, phone: true)?.code == .invalid)
        #expect(!rig.host.config.folders.contains(rig.root.path + "/srv"))
        // A Mac's grant (act or full) adds a folder anywhere, as before; a watch grant none.
        #expect(add(rig.root.path + "/srv", .watch, phone: false)?.code == .deniedControl)
        #expect(add(rig.root.path + "/srv", .act, phone: false)?.windowId == HostDaemon.windowID(rig.root.path + "/srv"))
        #expect(add(home + "/.config", .full, phone: false)?.ok == true)
    }

    private static func files(_ raw: Data) -> FilesResult? {
        guard StreamWire.type(raw) == "result", let r = try? JSONDecoder().decode(FilesResult.self, from: raw), ["m", "h", "o"].contains(r.id) else { return nil }
        return r
    }
}
