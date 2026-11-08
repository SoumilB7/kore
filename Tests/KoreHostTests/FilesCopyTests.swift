import Foundation
import Testing

@testable import KoreCore
@testable import KoreHost
@testable import LinkProtocol

/// Link 1.11: `fs.copy` and `fs.count`. Both ends inside served folders, links copied and counted
/// as themselves (never followed out), nothing replaced, a folder never into itself.
@Suite("kore-host file copies", .serialized)
struct FilesCopyTests {
    private struct Rig {
        let root: String
        let home: String
        let work: String
        let other: String
        let outside: String
        var files: HostFiles { HostFiles(home: home, served: [work, other]) }

        init() throws {
            root = "/tmp/khc-\(UUID().uuidString.prefix(8))"
            home = root + "/home"
            work = home + "/work"
            other = root + "/other"
            outside = root + "/secret"
            for folder in [work + "/src/deep", other, outside, home + "/notes"] {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            }
            try Data("hello\n".utf8).write(to: URL(fileURLWithPath: work + "/a.txt"))
            try Data("let a = 1\n".utf8).write(to: URL(fileURLWithPath: work + "/src/a.swift"))
            try Data("deep\n".utf8).write(to: URL(fileURLWithPath: work + "/src/deep/b.md"))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: work + "/src/a.swift")
            try FileManager.default.createSymbolicLink(atPath: work + "/src/up", withDestinationPath: "../a.txt")
            try Data("secret\n".utf8).write(to: URL(fileURLWithPath: outside + "/key.txt"))
            try FileManager.default.createSymbolicLink(atPath: work + "/escape", withDestinationPath: outside)
        }

        func text(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
        func finish() { try? FileManager.default.removeItem(atPath: root) }
    }

    @Test func aFolderCopiesWholeLinksAsLinksAndCountsTheSame() throws {
        let rig = try Rig()
        defer { rig.finish() }
        let copied = rig.files.copy(id: "1", from: rig.work + "/src", to: rig.other + "/src")
        #expect(copied.ok && copied.files == 3 && copied.dir == true)
        #expect(rig.text(rig.other + "/src/deep/b.md") == "deep\n")
        #expect((try FileManager.default.attributesOfItem(atPath: rig.other + "/src/a.swift")[.posixPermissions] as? Int) == 0o755)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: rig.other + "/src/up") == "../a.txt")
        let counted = rig.files.count(id: "2", path: rig.work + "/src")
        #expect(counted.ok && counted.files == copied.files && counted.size == copied.size && counted.size == 15)
        // Nothing hidden is left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.other) == ["src"])
        // A file, and a link to outside copied as the link itself.
        #expect(rig.files.copy(id: "3", from: rig.work + "/a.txt", to: rig.work + "/a copy.txt").ok)
        #expect(rig.text(rig.work + "/a copy.txt") == "hello\n")
        #expect(rig.files.copy(id: "4", from: rig.work + "/escape", to: rig.other + "/escape").ok)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: rig.other + "/escape") == rig.outside)
        let link = rig.files.count(id: "5", path: rig.work + "/escape")
        #expect(link.ok && link.files == 1 && link.dir == false && link.size == 0)
    }

    @Test func copiesOutsideTheServedFoldersOrOverAnythingAreRefused() throws {
        let rig = try Rig()
        defer { rig.finish() }
        let files = rig.files
        // Out of the served folders, either end.
        #expect(files.copy(id: "1", from: rig.outside + "/key.txt", to: rig.work + "/key.txt").code == .deniedPath)
        #expect(files.copy(id: "2", from: rig.work + "/a.txt", to: rig.home + "/notes/a.txt").code == .deniedPath)
        // Through a link out.
        #expect(files.copy(id: "3", from: rig.work + "/escape/key.txt", to: rig.work + "/key.txt").code == .deniedPath)
        #expect(files.copy(id: "4", from: rig.work + "/a.txt", to: rig.work + "/escape/a.txt").code == .deniedPath)
        #expect(!FileManager.default.fileExists(atPath: rig.outside + "/a.txt"))
        // Nothing replaced.
        try Data("mine\n".utf8).write(to: URL(fileURLWithPath: rig.other + "/a.txt"))
        #expect(files.copy(id: "5", from: rig.work + "/a.txt", to: rig.other + "/a.txt").code == .invalid)
        #expect(rig.text(rig.other + "/a.txt") == "mine\n")
        // A folder into itself, and a served folder's own place.
        #expect(files.copy(id: "6", from: rig.work + "/src", to: rig.work + "/src/deep/src").code == .invalid)
        #expect(files.copy(id: "7", from: rig.other + "/a.txt", to: rig.other).code == .invalid)
        // Not there; and relative or dotted paths.
        #expect(files.copy(id: "8", from: rig.work + "/gone", to: rig.work + "/x").code == .goneFile)
        #expect(files.copy(id: "9", from: "work/a.txt", to: rig.work + "/b.txt").code == .invalid)
        #expect(files.copy(id: "10", from: rig.work + "/../secret/key.txt", to: rig.work + "/k").code == .deniedPath)
        #expect(files.count(id: "11", path: rig.outside).code == .deniedPath)
        #expect(files.count(id: "12", path: rig.work + "/escape/key.txt").code == .deniedPath)
    }

    @Test func aCopySaysHowFarAndACancelLeavesNothing() throws {
        let rig = try Rig()
        defer { rig.finish() }
        try Data(repeating: 1, count: 5 * 1024 * 1024).write(to: URL(fileURLWithPath: rig.work + "/src/big.bin"))
        final class Said: @unchecked Sendable {
            let lock = NSLock()
            var frames: [(Int64, Int64)] = []
        }
        let said = Said()
        // Progress, a frame at most every 250 ms: the first comes at once, with the total.
        let run = CopyRun { bytes, total in said.lock.withLock { said.frames.append((bytes, total)) } }
        let copied = rig.files.copy(id: "1", from: rig.work + "/src", to: rig.other + "/src", run: run)
        #expect(copied.ok)
        let frames = said.lock.withLock { said.frames }
        #expect(!frames.isEmpty && frames.allSatisfy { $0.1 == 5 * 1024 * 1024 + 15 } && frames.first!.0 > 0)

        // Cancelled at its first MiB: refused, nothing left, the source whole.
        final class Holder: @unchecked Sendable { var run: CopyRun? }
        let holder = Holder()
        let stop = CopyRun { _, _ in holder.run?.cancel() }
        holder.run = stop
        let cancelled = rig.files.copy(id: "2", from: rig.work + "/src", to: rig.other + "/again", run: stop)
        #expect(!cancelled.ok && cancelled.message == "Cancelled.")
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.other) == ["src"])
        let source = rig.files.count(id: "3", path: rig.work + "/src")
        #expect(source.size == Int64(5_242_895) && source.files == 4)
    }

    @Test func onlyAFullGrantCopiesOrCounts() {
        let path = "/srv/work/a.txt"
        for kind in [ControlKind.fsCopy, .fsCount] {
            let args = kind == .fsCopy ? ControlArgs(from: path, to: path + ".2") : ControlArgs(path: path)
            if case .deny(let code, _) = LinkPolicy.checkBox(kind, args, nil, control: .standard) {
                #expect(code == .deniedControl)
            } else {
                Issue.record("\(kind) allowed without full control")
            }
            #expect(LinkPolicy.checkBox(kind, args, nil, control: .full) == .allow)
            #expect(kind.onFiles)
        }
        #expect(LinkPolicy.checkBox(.fsCopy, ControlArgs(from: "a.txt", to: path), nil, control: .full) != .allow)
        #expect(LinkPolicy.checkBox(.fsCopy, ControlArgs(from: path), nil, control: .full) != .allow)
        #expect(LinkPolicy.checkBox(.fsCount, ControlArgs(path: "x\ny"), nil, control: .full) != .allow)
        var cancel = ControlArgs()
        cancel.copyId = "c12.ab"
        #expect(LinkPolicy.checkBox(.fsCancel, cancel, nil, control: .full) == .allow)
        #expect(LinkPolicy.checkBox(.fsCancel, cancel, nil, control: .standard) != .allow)
        #expect(LinkPolicy.checkBox(.fsCancel, ControlArgs(), nil, control: .full) != .allow)
    }
}
