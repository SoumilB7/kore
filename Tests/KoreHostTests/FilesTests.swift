import Foundation
import Testing

@testable import KoreHost
@testable import LinkProtocol

/// Link 1.7's file commands: where a path may lead, what a listing and a read carry, and that
/// only a full grant gets them.
@Suite("kore-host files", .serialized)
@MainActor
struct FilesTests {
    /// A home with a served folder inside it, a served folder outside it, and a folder outside both.
    private struct Rig {
        let root: String
        let home: String
        let work: String
        let away: String
        let outside: String
        var files: HostFiles { HostFiles(home: home, served: [work, away]) }

        init() throws {
            root = "/tmp/khf-\(UUID().uuidString.prefix(8))"
            home = root + "/home"
            work = home + "/work"
            away = root + "/srv/app"
            outside = root + "/secret"
            for folder in [work + "/src", home + "/.config", away, outside] {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            }
            try Data("hello\n".utf8).write(to: URL(fileURLWithPath: work + "/README.md"))
            try Data("let a = 1\n".utf8).write(to: URL(fileURLWithPath: work + "/src/a.swift"))
            try Data("top secret\n".utf8).write(to: URL(fileURLWithPath: outside + "/key.txt"))
            try Data("dot\n".utf8).write(to: URL(fileURLWithPath: home + "/.profile"))
        }

        func finish() { try? FileManager.default.removeItem(atPath: root) }
    }

    @Test func homeListsFoldersFirstAndDotfilesOnlyWhenAsked() throws {
        let rig = try Rig()
        defer { rig.finish() }
        try Data().write(to: URL(fileURLWithPath: rig.home + "/b.txt"))
        let plain = rig.files.list(id: "1", path: nil, hidden: false)
        #expect(plain.ok)
        #expect(plain.path == rig.home)
        #expect(plain.entries?.map(\.name) == ["work", "b.txt"])
        #expect(plain.entries?.first?.kind == .dir)
        #expect(plain.entries?.last?.size == 0)
        let all = rig.files.list(id: "2", path: rig.home + "/", hidden: true)
        #expect(all.entries?.map(\.name) == [".config", "work", ".profile", "b.txt"])
    }

    @Test func outsideTheHomeOnlyServedFoldersList() throws {
        let rig = try Rig()
        defer { rig.finish() }
        #expect(rig.files.list(id: "1", path: rig.away, hidden: false).ok)
        let refused = rig.files.list(id: "2", path: rig.outside, hidden: false)
        #expect(!refused.ok)
        #expect(refused.code == .deniedPath)
        // `..` is resolved before the check: it can't climb out of the home.
        let climbed = rig.files.list(id: "3", path: rig.home + "/work/../../secret", hidden: false)
        #expect(climbed.code == .deniedPath)
        #expect(rig.files.list(id: "4", path: "/", hidden: false).code == .deniedPath)
        #expect(rig.files.list(id: "5", path: "work", hidden: false).code == .invalid)
        #expect(rig.files.list(id: "6", path: rig.home + "/nope", hidden: false).code == .goneFile)
    }

    @Test func aLinkOutIsListedAsALinkAndNeverFollowed() throws {
        let rig = try Rig()
        defer { rig.finish() }
        try FileManager.default.createSymbolicLink(atPath: rig.work + "/escape", withDestinationPath: rig.outside)
        try FileManager.default.createSymbolicLink(atPath: rig.work + "/key", withDestinationPath: rig.outside + "/key.txt")
        try FileManager.default.createSymbolicLink(atPath: rig.work + "/inner", withDestinationPath: rig.work + "/src")
        let listed = rig.files.list(id: "1", path: rig.work, hidden: false)
        let escape = listed.entries?.first { $0.name == "escape" }
        #expect(escape?.kind == .link)
        #expect(escape?.dir == true)
        #expect(listed.entries?.first { $0.name == "key" }?.kind == .link)
        #expect(rig.files.list(id: "2", path: rig.work + "/escape", hidden: false).code == .deniedPath)
        #expect(rig.files.read(id: "3", path: rig.work + "/escape/key.txt", max: nil).code == .deniedPath)
        #expect(rig.files.read(id: "4", path: rig.work + "/key", max: nil).code == .deniedPath)
        // A link that stays inside the folder is fine.
        #expect(rig.files.list(id: "5", path: rig.work + "/inner", hidden: false).entries?.map(\.name) == ["a.swift"])
    }

    @Test func readsTextCutTextImagesAndBinaryOnlyInServedFolders() throws {
        let rig = try Rig()
        defer { rig.finish() }
        let text = rig.files.read(id: "1", path: rig.work + "/README.md", max: nil)
        #expect(text.kind == .text)
        #expect(text.text == "hello\n")
        #expect(text.size == 6)
        #expect(text.truncated == nil)
        let cut = rig.files.read(id: "2", path: rig.work + "/README.md", max: 3)
        #expect(cut.text == "hel")
        #expect(cut.truncated == true)
        // A character cut in half at the end is dropped, not mangled.
        try Data("aé".utf8).write(to: URL(fileURLWithPath: rig.work + "/e.txt"))
        #expect(rig.files.read(id: "3", path: rig.work + "/e.txt", max: 2).text == "a")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2])
        try png.write(to: URL(fileURLWithPath: rig.work + "/p.png"))
        let image = rig.files.read(id: "4", path: rig.work + "/p.png", max: nil)
        #expect(image.kind == .image)
        #expect(image.data.flatMap { Data(base64Encoded: $0) } == png)
        try Data([0, 1, 2, 3]).write(to: URL(fileURLWithPath: rig.work + "/blob.bin"))
        let binary = rig.files.read(id: "5", path: rig.work + "/blob.bin", max: nil)
        #expect(binary.kind == .binary)
        #expect(binary.text == nil)
        // In the home but not served: the browser lists it, nothing reads it.
        #expect(rig.files.read(id: "6", path: rig.home + "/.profile", max: nil).code == .deniedPath)
        #expect(rig.files.read(id: "7", path: rig.work + "/src", max: nil).code == .invalid)
        #expect(rig.files.read(id: "8", path: rig.away + "/../../secret/key.txt", max: nil).code == .deniedPath)
    }

    @Test func mkdirMakesOneFolderInTheHomeOrAServedFolder() throws {
        let rig = try Rig()
        defer { rig.finish() }
        let made = rig.files.mkdir(id: "1", path: rig.home + "/new")
        #expect(made.ok)
        #expect(made.path == rig.home + "/new")
        #expect(FileManager.default.fileExists(atPath: rig.home + "/new"))
        #expect(rig.files.mkdir(id: "2", path: rig.home + "/new").code == .invalid)
        #expect(rig.files.mkdir(id: "3", path: rig.outside + "/x").code == .deniedPath)
        #expect(rig.files.mkdir(id: "4", path: rig.home + "/a/b").code == .goneFile)
        #expect(rig.files.mkdir(id: "5", path: rig.away + "/made").ok)
    }

    @Test func aHugeFolderStopsAtTheCap() throws {
        let rig = try Rig()
        defer { rig.finish() }
        let big = rig.work + "/big"
        try FileManager.default.createDirectory(atPath: big, withIntermediateDirectories: true)
        for i in 0...LinkFiles.listMax { FileManager.default.createFile(atPath: big + "/f\(i)", contents: nil) }
        let listed = rig.files.list(id: "1", path: big, hidden: false)
        #expect(listed.entries?.count == LinkFiles.listMax)
        #expect(listed.more == true)
    }

    @Test func onlyAFullGrantGetsFilesOverTheLink() async throws {
        let rig = try HostRig()
        defer { rig.finish() }
        try rig.host.start()
        try Data("hi".utf8).write(to: rig.folder.appendingPathComponent("a.txt"))
        let store = GrantStore(rig.paths.grants)
        for (control, name) in [(GrantControl.act, "act"), (.full, "full")] {
            let grant = try store.allow(name, control: control, socket: rig.paths.socket)
            let client = try Client(rig.paths.socket)
            try await until { !client.got.isEmpty }
            client.hello(grant: grant)
            try await until { client.got.count >= 3 }
            client.socket.send(.cmd(id: "l", .control(.fsList, ControlArgs(path: rig.folder.path))))
            client.socket.send(.cmd(id: "r", .control(.fsRead, ControlArgs(path: rig.folder.path + "/a.txt"))))
            try await until { client.raws.compactMap(Self.result).count >= 2 }
            let results = Dictionary(client.raws.compactMap(Self.result).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            if control == .full {
                #expect(results["l"]?.entries?.map(\.name) == ["a.txt"])
                #expect(results["r"]?.text == "hi")
            } else {
                #expect(results["l"]?.code == .deniedControl)
                #expect(results["r"]?.code == .deniedControl)
            }
            client.socket.close()
        }
    }

    private static func result(_ raw: Data) -> FilesResult? {
        guard StreamWire.type(raw) == "result" else { return nil }
        return try? JSONDecoder().decode(FilesResult.self, from: raw)
    }
}
