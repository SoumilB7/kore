import Foundation
import Testing

@testable import KoreCore
@testable import KoreHost
@testable import LinkProtocol

/// Link 1.8: writing, making, renaming, trashing and finding a served folder's files, and
/// watching its open folders. Only inside served folders, links never followed out, nothing
/// deleted for good.
@Suite("kore-host file edits", .serialized)
@MainActor
struct FilesEditTests {
    private struct Rig {
        let root: String
        let home: String
        let work: String
        let outside: String
        var files: HostFiles { HostFiles(home: home, served: [work]) }

        init() throws {
            root = "/tmp/khe-\(UUID().uuidString.prefix(8))"
            home = root + "/home"
            work = home + "/work"
            outside = root + "/secret"
            for folder in [work + "/src", home + "/notes", outside] {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            }
            try Data("hello\n".utf8).write(to: URL(fileURLWithPath: work + "/a.txt"))
            try Data("let a = 1\n".utf8).write(to: URL(fileURLWithPath: work + "/src/a.swift"))
            try Data("secret\n".utf8).write(to: URL(fileURLWithPath: outside + "/key.txt"))
            try FileManager.default.createSymbolicLink(atPath: work + "/escape", withDestinationPath: outside)
            try FileManager.default.createSymbolicLink(atPath: work + "/key", withDestinationPath: outside + "/key.txt")
        }

        func text(_ path: String) -> String? { (try? String(contentsOfFile: path, encoding: .utf8)) }
        func finish() { try? FileManager.default.removeItem(atPath: root) }
    }

    @Test func aWriteChecksWhatTheClientReadAndKeepsTheMode() throws {
        let rig = try Rig()
        defer { rig.finish() }
        let path = rig.work + "/a.txt"
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        let read = rig.files.read(id: "r", path: path, max: nil)
        let base = FileStamp(size: read.size ?? 0, mtime: read.mtime ?? 0)
        let written = rig.files.write(id: "1", path: path, bytes: Data("hi\n".utf8), base: base)
        #expect(written.ok)
        #expect(rig.text(path) == "hi\n")
        #expect(written.size == 3)
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o755)
        // The old base is stale now: changed on the box since.
        let stale = rig.files.write(id: "2", path: path, bytes: Data("mine\n".utf8), base: base)
        #expect(stale.code == .conflict)
        #expect(rig.text(path) == "hi\n")
        let fresh = rig.files.write(id: "3", path: path, bytes: Data("mine\n".utf8), base: FileStamp(size: written.size ?? 0, mtime: written.mtime ?? 0))
        #expect(fresh.ok)
        // Gone since it was read.
        #expect(rig.files.write(id: "4", path: rig.work + "/gone.txt", bytes: Data(), base: base).code == .conflict)
        // New, with no base.
        #expect(rig.files.write(id: "5", path: rig.work + "/new.txt", bytes: Data("n".utf8), base: nil).ok)
        #expect(!FileManager.default.fileExists(atPath: rig.work + "/.a.txt.kore"))
    }

    @Test func editsStayInsideServedFoldersAndNeverThroughALinkOut() throws {
        let rig = try Rig()
        defer { rig.finish() }
        let bytes = Data("x".utf8)
        // The home is listed, never written.
        #expect(rig.files.write(id: "1", path: rig.home + "/notes/n.txt", bytes: bytes, base: nil).code == .deniedPath)
        #expect(rig.files.create(id: "2", path: rig.home + "/n.txt", dir: false).code == .deniedPath)
        #expect(rig.files.write(id: "3", path: rig.work + "/../../secret/key.txt", bytes: bytes, base: nil).code == .deniedPath)
        #expect(rig.files.write(id: "4", path: rig.work + "/escape/key.txt", bytes: bytes, base: nil).code == .deniedPath)
        #expect(rig.files.write(id: "5", path: rig.work + "/key", bytes: bytes, base: nil).code == .deniedPath)
        #expect(rig.files.create(id: "6", path: rig.work + "/escape/new", dir: true).code == .deniedPath)
        #expect(rig.files.rename(id: "7", from: rig.work + "/a.txt", to: rig.home + "/notes/a.txt").code == .deniedPath)
        #expect(rig.files.rename(id: "8", from: rig.work + "/a.txt", to: rig.work + "/escape/a.txt").code == .deniedPath)
        #expect(rig.files.delete(id: "9", path: rig.home + "/notes", trash: .mac(rig.home + "/.Trash")).code == .deniedPath)
        #expect(rig.files.delete(id: "10", path: rig.work + "/escape/key.txt", trash: .mac(rig.home + "/.Trash")).code == .deniedPath)
        #expect(rig.text(rig.outside + "/key.txt") == "secret\n")
        // The served folder itself stays.
        #expect(rig.files.delete(id: "11", path: rig.work, trash: .mac(rig.home + "/.Trash")).code == .invalid)
        #expect(rig.files.rename(id: "12", from: rig.work, to: rig.work + "2").code != nil)
    }

    @Test func createAndRenameNeverReplaceAnything() throws {
        let rig = try Rig()
        defer { rig.finish() }
        #expect(rig.files.create(id: "1", path: rig.work + "/new.txt", dir: false).ok)
        #expect(rig.files.create(id: "2", path: rig.work + "/lib", dir: true).ok)
        #expect(rig.files.create(id: "3", path: rig.work + "/a.txt", dir: false).code == .invalid)
        #expect(rig.text(rig.work + "/a.txt") == "hello\n")
        #expect(rig.files.rename(id: "4", from: rig.work + "/new.txt", to: rig.work + "/a.txt").code == .invalid)
        #expect(rig.files.rename(id: "5", from: rig.work + "/new.txt", to: rig.work + "/lib/moved.txt").ok)
        #expect(FileManager.default.fileExists(atPath: rig.work + "/lib/moved.txt"))
        #expect(rig.files.rename(id: "6", from: rig.work + "/src", to: rig.work + "/src/inner").code == .invalid)
        // A link moves as itself.
        #expect(rig.files.rename(id: "7", from: rig.work + "/key", to: rig.work + "/key2").ok)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: rig.work + "/key2")) == rig.outside + "/key.txt")
    }

    @Test func aDeleteMovesToTheTrashFreedesktopOrMac() throws {
        let rig = try Rig()
        defer { rig.finish() }
        let trash = rig.home + "/.local/share/Trash"
        #expect(rig.files.delete(id: "1", path: rig.work + "/a.txt", trash: .freedesktop(trash)).ok)
        #expect(!FileManager.default.fileExists(atPath: rig.work + "/a.txt"))
        #expect(rig.text(trash + "/files/a.txt") == "hello\n")
        let info = rig.text(trash + "/info/a.txt.trashinfo") ?? ""
        #expect(info.hasPrefix("[Trash Info]\nPath=" + rig.work + "/a.txt\nDeletionDate="))
        try Data("again\n".utf8).write(to: URL(fileURLWithPath: rig.work + "/a.txt"))
        #expect(rig.files.delete(id: "2", path: rig.work + "/a.txt", trash: .freedesktop(trash)).ok)
        #expect(rig.text(trash + "/files/a.2.txt") == "again\n")
        #expect(FileManager.default.fileExists(atPath: trash + "/info/a.2.txt.trashinfo"))
        // A folder, and the Mac's way.
        #expect(rig.files.delete(id: "3", path: rig.work + "/src", trash: .mac(rig.home + "/.Trash")).ok)
        #expect(rig.text(rig.home + "/.Trash/src/a.swift") == "let a = 1\n")
        // A link goes as itself; what it leads to stays.
        #expect(rig.files.delete(id: "4", path: rig.work + "/key", trash: .mac(rig.home + "/.Trash")).ok)
        #expect(rig.text(rig.outside + "/key.txt") == "secret\n")
        #expect(rig.files.delete(id: "5", path: rig.work + "/nope", trash: .mac(rig.home + "/.Trash")).code == .goneFile)
    }

    @Test func searchFindsNamesAndLinesWithinCaps() throws {
        let rig = try Rig()
        defer { rig.finish() }
        try Data("ignored.txt\nbuild/\n".utf8).write(to: URL(fileURLWithPath: rig.work + "/.gitignore"))
        try Data("hello there\n".utf8).write(to: URL(fileURLWithPath: rig.work + "/ignored.txt"))
        try FileManager.default.createDirectory(atPath: rig.work + "/build", withIntermediateDirectories: true)
        try Data("hello build\n".utf8).write(to: URL(fileURLWithPath: rig.work + "/build/out.txt"))
        let names = rig.files.search(id: "1", root: rig.work, query: "a.swift", text: false, max: nil, rg: nil)
        #expect(names.hits?.first?.path == rig.work + "/src/a.swift")
        let fuzzy = rig.files.search(id: "2", root: rig.work, query: "srcas", text: false, max: nil, rg: nil)
        #expect(fuzzy.hits?.map(\.path) == [rig.work + "/src/a.swift"])
        let lines = rig.files.search(id: "3", root: rig.work, query: "HELLO", text: true, max: nil, rg: nil)
        #expect(lines.hits == [FileHit(path: rig.work + "/a.txt", line: 1, text: "hello")])
        // Never through the link out, never what .gitignore names.
        #expect(rig.files.search(id: "4", root: rig.work, query: "secret", text: true, max: nil, rg: nil).hits == [])
        for i in 0..<30 { try Data("hello \(i)\n".utf8).write(to: URL(fileURLWithPath: rig.work + "/f\(i).txt")) }
        let capped = rig.files.search(id: "5", root: rig.work, query: "hello", text: true, max: 10, rg: nil)
        #expect(capped.hits?.count == 10)
        #expect(capped.more == true)
        #expect(rig.files.search(id: "6", root: rig.home, query: "a", text: false, max: nil, rg: nil).code == .deniedPath)
        if let rg = HostFiles.ripgrep() {
            let fast = rig.files.search(id: "7", root: rig.work, query: "let a", text: true, max: nil, rg: rg)
            #expect(fast.hits == [FileHit(path: rig.work + "/src/a.swift", line: 1, text: "let a = 1")])
        }
    }

    @Test func aReadWithTheStampHeldSendsNothingAgain() throws {
        let rig = try Rig()
        defer { rig.finish() }
        let first = rig.files.read(id: "1", path: rig.work + "/a.txt", max: nil)
        let again = rig.files.read(id: "2", path: rig.work + "/a.txt", max: nil, base: FileStamp(size: first.size ?? 0, mtime: first.mtime ?? 0))
        #expect(again.unchanged == true)
        #expect(again.text == nil)
        let stale = rig.files.read(id: "3", path: rig.work + "/a.txt", max: nil, base: FileStamp(size: 1, mtime: 1))
        #expect(stale.text == "hello\n")
    }

    @Test func textSearchSendsPagesAndAStoppedOneEndsAtOnce() throws {
        let rig = try Rig()
        defer { rig.finish() }
        for i in 0..<250 { try Data("needle \(i)\n".utf8).write(to: URL(fileURLWithPath: rig.work + "/n\(i).txt")) }
        let pages = Box<[[FileHit]]>([])
        let run = SearchRun { page in pages.value.append(page) }
        let result = rig.files.search(id: "1", root: rig.work, query: "needle", text: true, max: 1000, rg: nil, run: run)
        #expect(pages.value.count == 2)
        #expect(pages.value.allSatisfy { $0.count == SearchRun.page })
        #expect((result.hits?.count ?? 0) + pages.value.reduce(0) { $0 + $1.count } == 250)
        let stopped = SearchRun()
        stopped.cancel()
        let none = rig.files.search(id: "2", root: rig.work, query: "needle", text: true, max: 1000, rg: nil, run: stopped)
        #expect(none.hits == [])
        #expect(none.more == true)
    }

    @Test func aChangeSaysItsFolderAndNames() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let got = Box<[FilesChanged]>([])
        let watches = FolderWatches { got.value.append($0) }
        defer { watches.stop() }
        let real = HostFiles.real(rig.work) ?? rig.work
        #expect(watches.set([(rig.work, real)]))
        try await Task.sleep(for: .milliseconds(200))
        try Data("x".utf8).write(to: URL(fileURLWithPath: rig.work + "/fresh.txt"))
        try await until { !got.value.isEmpty }
        #expect(got.value.first?.folders == [rig.work])
        #expect(got.value.first?.names?[rig.work]?.contains("fresh.txt") == true)
    }

    @Test func onlyAFullGrantEditsAndTheOpenFoldersAreWatched() async throws {
        let rig = try HostRig()
        defer { rig.finish() }
        try rig.host.start()
        let folder = rig.folder.path
        let store = GrantStore(rig.paths.grants)
        let act = try store.allow("act", control: .act, socket: rig.paths.socket)
        let client = try Client(rig.paths.socket)
        try await until { !client.got.isEmpty }
        client.hello(grant: act)
        try await until { client.got.count >= 3 }
        for (id, kind, args) in [
            ("w", ControlKind.fsWrite, ControlArgs(text: "x", path: folder + "/x")), ("c", .fsCreate, ControlArgs(path: folder + "/y")),
            ("d", .fsDelete, ControlArgs(path: folder + "/x")), ("m", .fsRename, ControlArgs(from: folder + "/x", to: folder + "/z")),
            ("s", .fsSearch, ControlArgs(root: folder, query: "x")), ("v", .fsWatch, ControlArgs(folders: [folder])),
        ] {
            client.socket.send(.cmd(id: id, .control(kind, args)))
        }
        try await until { client.raws.compactMap(Self.result).count >= 6 }
        #expect(client.raws.compactMap(Self.result).allSatisfy { $0.code == .deniedControl })
        client.socket.close()

        let full = try store.allow("full", control: .full, socket: rig.paths.socket)
        let owner = try Client(rig.paths.socket)
        try await until { !owner.got.isEmpty }
        owner.hello(grant: full)
        try await until { owner.got.count >= 3 }
        owner.socket.send(.cmd(id: "v", .control(.fsWatch, ControlArgs(folders: [folder]))))
        try await until { owner.raws.compactMap(Self.result).contains { $0.id == "v" } }
        #expect(owner.raws.compactMap(Self.result).first { $0.id == "v" }?.watching == true)
        owner.socket.send(.cmd(id: "c", .control(.fsCreate, ControlArgs(path: folder + "/made.txt"))))
        try await until { owner.raws.contains { (try? JSONDecoder().decode(FilesChanged.self, from: $0))?.folders == [folder] } }
        owner.socket.send(.cmd(id: "u", .control(.fsWatch, ControlArgs(folders: []))))
        owner.socket.close()
    }

    /// A full grant with two folders watched, then left alone: the process's idle wakeups over
    /// 10 s, by `top` (set `KORE_IDLE_MEASURE`). Daemon, client and test runner are one process
    /// here, so this is an upper bound for the box's own.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KORE_IDLE_MEASURE"] != nil))
    func anIdleWatchWakesNothing() async throws {
        let rig = try HostRig()
        defer { rig.finish() }
        try rig.host.start()
        let folder = rig.folder.path
        try FileManager.default.createDirectory(atPath: folder + "/src", withIntermediateDirectories: true)
        let grant = try GrantStore(rig.paths.grants).allow("full", control: .full, socket: rig.paths.socket)
        let client = try Client(rig.paths.socket)
        try await until { !client.got.isEmpty }
        client.hello(grant: grant)
        try await until { client.got.count >= 3 }
        client.socket.send(.cmd(id: "v", .control(.fsWatch, ControlArgs(folders: [folder, folder + "/src"]))))
        try await until { client.raws.compactMap(Self.result).contains { $0.id == "v" } }
        try await Task.sleep(for: .seconds(1))
        let frames = client.raws.count
        let top = Process()
        top.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        top.arguments = ["-l", "2", "-s", "10", "-pid", String(getpid()), "-stats", "pid,idlew,cpu"]
        let out = Pipe()
        top.standardOutput = out
        try top.run()
        await Task.detached { top.waitUntilExit() }.value
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let line = text.split(separator: "\n").last { $0.hasPrefix(String(getpid())) } ?? ""
        print("idle-measure: \(line) · frames while idle: \(client.raws.count - frames)")
        #expect(client.raws.count == frames)
    }

    private static func result(_ raw: Data) -> FilesResult? {
        guard StreamWire.type(raw) == "result" else { return nil }
        return try? JSONDecoder().decode(FilesResult.self, from: raw)
    }
}

/// A value a closure can change.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
