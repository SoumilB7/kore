import Foundation
import HostClient
import KoreCore
import KoreHost
import LinkProtocol
import Testing

/// Copy and move between any two places: the route each pair takes, Finder's names, and real
/// carries against kore-hosts in this process (their files over the link, the bytes by rsync or
/// tar through stand-in ssh programs that run here).
@MainActor
@Suite("file carries", .serialized)
struct FileCarryTests {
    // MARK: Routes and names

    @Test func eachPairOfPlacesTakesItsRoute() {
        let mac = FilePlace.mac("/Users/me/a"), macFolder = FilePlace.mac("/Users/me/b")
        let box = FilePlace.box(alias: "one", path: "/srv/a"), boxFolder = FilePlace.box(alias: "one", path: "/srv/b")
        let other = FilePlace.box(alias: "two", path: "/home/x")
        let expected: [(FilePlace, FilePlace, Bool, CarryRoute)] = [
            (mac, macFolder, true, .macRename), (mac, macFolder, false, .macCopy),
            (box, boxFolder, true, .boxRename), (box, boxFolder, false, .boxCopy),
            (mac, boxFolder, true, .macToBox), (mac, boxFolder, false, .macToBox),
            (box, macFolder, true, .boxToMac), (box, macFolder, false, .boxToMac),
            (box, other, true, .boxToBox), (box, other, false, .boxToBox),
        ]
        for (from, into, move, route) in expected {
            #expect(CarryRoute.pick(from: from, into: into, move: move) == route, "\(from) → \(into) move \(move)")
        }
        #expect(CarryRoute.allCases.filter(\.crossDevice) == [.macToBox, .boxToMac, .boxToBox])
        #expect(CarryRoute.allCases.filter(\.renames) == [.macRename, .boxRename])
        // A folder never into itself or below it; the same path on another device is fine.
        #expect(FileCarry.refusal(CarryItem(source: box), into: box.child("deep")) != nil)
        #expect(FileCarry.refusal(CarryItem(source: box), into: box) != nil)
        #expect(FileCarry.refusal(CarryItem(source: .box(alias: "two", path: "/srv/a")), into: box.child("deep")) == nil)
        #expect(FileCarry.refusal(CarryItem(source: mac), into: .mac("/Users/me/a/b")) != nil)
        #expect(FileCarry.refusal(CarryItem(source: mac), into: .mac("/Users/me/ab")) == nil)
        // Box paths as the box keeps them, nothing else.
        for bad in ["relative", "/srv/../etc", "/srv/./a", "/srv//a", "/srv/a/", "/", "/srv/a\nb"] {
            #expect(!FileCarry.plain(bad), "\(bad)")
            #expect(FileCarry.refusal(CarryItem(source: .box(alias: "one", path: bad)), into: macFolder) != nil)
        }
        #expect(FileCarry.refusal(CarryItem(source: mac, name: "../x"), into: boxFolder) != nil)
    }

    @Test func clashesAreNamedAsFinderNamesThem() {
        let taken: Set<String> = ["a.txt", "a 2.txt", "notes", "a copy.txt", ".env"]
        func free(_ name: String, _ duplicate: Bool) -> String { CopyNames.free(name, duplicate: duplicate) { taken.contains($0) } }
        #expect(free("b.txt", false) == "b.txt")
        #expect(free("a.txt", false) == "a 3.txt")
        #expect(free("notes", false) == "notes 2")
        #expect(free(".env", false) == ".env 2")
        #expect(free("a.txt", true) == "a copy 2.txt")
        #expect(free("b.txt", true) == "b copy.txt")
        #expect(free("archive.tar.gz", false) == "archive.tar.gz")
    }

    // MARK: Carries against real hosts

    /// A box: a kore-host serving `work` under its root, its link, and a stand-in ssh.
    struct Box {
        let rig: BoxRig
        let connection: HostConnection
        let carry: CarryBox
        var work: String { rig.folder.path }
    }

    func box(_ alias: String) async throws -> Box {
        let rig = try BoxRig()
        let connection = rig.connection()
        connection.retain()
        #expect(await until(5) { connection.isOnline })
        return Box(rig: rig, connection: connection, carry: CarryBox(alias: alias, files: connection, ssh: try fakeSSH(rig.root)))
    }

    func finish(_ boxes: Box...) {
        for box in boxes {
            box.connection.release()
            box.rig.finish()
        }
    }

    /// A folder with a few files, a nested folder and a link, under `parent`.
    func tree(_ parent: String, _ name: String = "proj") throws -> String {
        let root = parent + "/" + name
        try FileManager.default.createDirectory(atPath: root + "/src/deep", withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: URL(fileURLWithPath: root + "/README.md"))
        try Data(repeating: 7, count: 300_000).write(to: URL(fileURLWithPath: root + "/src/blob.bin"))
        try Data("deep\n".utf8).write(to: URL(fileURLWithPath: root + "/src/deep/b.md"))
        try FileManager.default.createSymbolicLink(atPath: root + "/src/readme", withDestinationPath: "../README.md")
        return root
    }

    func macFolder() throws -> String {
        let path = "/tmp/kfc-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func names(_ folder: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted() }

    @Test func aMacFolderGoesToABoxAndComesBack() async throws {
        let b = try await box("one")
        let mac = try macFolder()
        defer {
            finish(b)
            try? FileManager.default.removeItem(atPath: mac)
        }
        let source = try tree(mac)
        let count = try #require(CarryCount.mac(source))
        #expect(count == CarryCount(files: 4, bytes: 300_011, dir: true))

        // Copy to the box: all there, the Mac's stays, nothing hidden is left.
        let up = FileCarry(items: [CarryItem(source: .mac(source))], into: .box(alias: "one", path: b.work), move: false, boxes: ["one": b.carry])
        let sent = await up.run()
        #expect(sent.failure == nil && sent.landed == [.box(alias: "one", path: b.work + "/proj")])
        #expect(CarryCount.mac(b.work + "/proj") == count)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: b.work + "/proj/src/readme") == "../README.md")
        #expect(names(b.work) == ["proj"] && FileManager.default.fileExists(atPath: source))

        // Back to the Mac as a move, under a name of its own: copy, check, then the box's trash.
        let back = try macFolder()
        defer { try? FileManager.default.removeItem(atPath: back) }
        let down = FileCarry(
            items: [CarryItem(source: .box(alias: "one", path: b.work + "/proj"), name: "proj 2")], into: .mac(back), move: true, boxes: ["one": b.carry])
        let brought = await down.run()
        #expect(brought.failure == nil && brought.landed == [.mac(back + "/proj 2")])
        #expect(down.steps == ["copy proj 2", "verify proj 2", "trash proj"])
        #expect(CarryCount.mac(back + "/proj 2") == count && names(back) == ["proj 2"])
        #expect(!FileManager.default.fileExists(atPath: b.work + "/proj"))
        // In the box's trash, not gone.
        #expect(FileManager.default.fileExists(atPath: b.rig.root.appendingPathComponent(".Trash/proj").path))
    }

    @Test func aFileMovesFromOneBoxToAnotherThroughTheMac() async throws {
        let a = try await box("one"), b = try await box("two")
        defer { finish(a, b) }
        let source = try tree(a.work)
        try Data("theirs\n".utf8).write(to: URL(fileURLWithPath: b.work + "/README.md"))
        let boxes = ["one": a.carry, "two": b.carry]
        // A folder copied, then a file moved over a name that's taken (the user chose Replace).
        let copy = FileCarry(items: [CarryItem(source: .box(alias: "one", path: source))], into: .box(alias: "two", path: b.work), move: false, boxes: boxes)
        let copied = await copy.run()
        #expect(copied.failure == nil)
        #expect(CarryCount.mac(b.work + "/proj") == CarryCount.mac(source))
        let move = FileCarry(
            items: [CarryItem(source: .box(alias: "one", path: source + "/README.md"), replace: true)], into: .box(alias: "two", path: b.work), move: true,
            boxes: boxes)
        let moved = await move.run()
        #expect(moved.failure == nil)
        #expect(move.steps == ["copy README.md", "verify README.md", "trash README.md", "trash README.md"])
        #expect((try? String(contentsOfFile: b.work + "/README.md", encoding: .utf8)) == "hello\n")
        #expect(!FileManager.default.fileExists(atPath: source + "/README.md"))
        #expect(names(b.work) == ["README.md", "proj"])
    }

    @Test func aFailedOrCancelledMoveKeepsTheSourceAndLeavesNothing() async throws {
        let b = try await box("one")
        let mac = try macFolder()
        defer {
            finish(b)
            try? FileManager.default.removeItem(atPath: mac)
        }
        let source = try tree(mac)
        // ssh that fails: rsync stops, the source stays, nothing partial on either side.
        let broken = CarryBox(alias: "one", files: b.connection, ssh: SyncBox.via("/usr/bin/false", alias: "one", base: nil))
        let failing = FileCarry(items: [CarryItem(source: .mac(source))], into: .box(alias: "one", path: b.work), move: true, boxes: ["one": broken])
        let failed = await failing.run()
        #expect(failed.failure != nil && failed.landed.isEmpty)
        #expect(failing.steps == ["copy proj"])
        #expect(CarryCount.mac(source)?.files == 4 && names(b.work).isEmpty)

        // A folder that's gone on the box: refused before anything moves.
        let nowhere = FileCarry(items: [CarryItem(source: .mac(source))], into: .box(alias: "one", path: b.work + "/gone"), move: true, boxes: ["one": b.carry])
        #expect(await nowhere.run().failure != nil && nowhere.steps.isEmpty)
        // Outside the box's served folders: refused by the box.
        let outside = FileCarry(items: [CarryItem(source: .mac(source))], into: .box(alias: "one", path: b.rig.root.path), move: true, boxes: ["one": b.carry])
        #expect(await outside.run().failure != nil && outside.steps.isEmpty)

        // Cancelled while the bytes cross: the source stays, the partial copy goes.
        let slow = try fakeSlowSSH(b.rig.root)
        let cancelled = FileCarry(items: [CarryItem(source: .mac(source))], into: .box(alias: "one", path: b.work), move: true,
            boxes: ["one": CarryBox(alias: "one", files: b.connection, ssh: slow)])
        let running = Task { await cancelled.run() }
        try await Task.sleep(for: .milliseconds(400))
        cancelled.cancel()
        let ended = await running.value
        #expect(ended.cancelled && ended.landed.isEmpty)
        #expect(!cancelled.steps.contains("trash proj"))
        #expect(CarryCount.mac(source)?.files == 4 && names(b.work).isEmpty)
    }

    /// rsync that prints nothing: the bytes at the hidden copy on the box drive the progress,
    /// measured by the box (`fs.count`) every poll while it runs, and no more once it ends.
    @Test func bytesLandedOnTheBoxDriveTheProgressWhileRsyncIsSilent() async throws {
        let b = try await box("one")
        let mac = try macFolder()
        defer {
            finish(b)
            try? FileManager.default.removeItem(atPath: mac)
        }
        let source = try tree(mac)
        // The box measures what's there (the real `fs.count`).
        try FileManager.default.createDirectory(atPath: b.work + "/.proj.kore-0000abcd", withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1234).write(to: URL(fileURLWithPath: b.work + "/.proj.kore-0000abcd/x"))
        let probe = FileCarry(items: [], into: .box(alias: "one", path: b.work), move: false, boxes: ["one": b.carry])
        #expect(await probe.landedBytes(.box(alias: "one", path: b.work + "/.proj.kore-0000abcd")) == 1234)
        #expect(await probe.landedBytes(.box(alias: "one", path: b.work + "/.gone.kore-0000abcd")) == nil)
        #expect(await probe.landedBytes(.mac(source)) == 300_011)
        try FileManager.default.removeItem(atPath: b.work + "/.proj.kore-0000abcd")

        // A slow ssh: rsync says nothing for a while; the measures still move the bar.
        let carry = FileCarry(items: [CarryItem(source: .mac(source))], into: .box(alias: "one", path: b.work), move: false,
            boxes: ["one": CarryBox(alias: "one", files: b.connection, ssh: try fakeSlowSSH(b.rig.root))])
        carry.pollEvery = .milliseconds(50)
        carry.tick = .milliseconds(20)
        var measured: [FilePlace] = []
        carry.measure = { place in
            measured.append(place)
            return Int64(measured.count) * 10_000
        }
        var told: [Int64] = []
        carry.onProgress = { told.append(carry.bytes) }
        let running = Task { await carry.run() }
        #expect(await until(5) { carry.bytes >= 30_000 })
        #expect(told.contains { $0 > 0 && $0 < 300_011 })
        // What it measured: the hidden copy in the box folder.
        let place = try #require(measured.first)
        #expect(place.alias == "one" && place.parent.path == b.work && FileCarry.isStaging(place.name) && place.name.hasPrefix(".proj."))
        carry.cancel()
        _ = await running.value
        let polls = carry.polls
        try await Task.sleep(for: .milliseconds(250))
        #expect(carry.polls == polls)
    }

    @Test func onOneBoxAMoveRenamesAndACopyIsTheBoxs() async throws {
        let b = try await box("one")
        defer { finish(b) }
        let source = try tree(b.work)
        try FileManager.default.createDirectory(atPath: b.work + "/dest", withIntermediateDirectories: true)
        let boxes = ["one": b.carry]
        let copy = FileCarry(items: [CarryItem(source: .box(alias: "one", path: source), name: "proj copy")], into: .box(alias: "one", path: b.work), move: false, boxes: boxes)
        #expect(await copy.run().failure == nil)
        #expect(CarryCount.mac(b.work + "/proj copy") == CarryCount.mac(source))
        let move = FileCarry(items: [CarryItem(source: .box(alias: "one", path: source))], into: .box(alias: "one", path: b.work + "/dest"), move: true, boxes: boxes)
        #expect(await move.run().failure == nil && move.steps == ["rename proj"])
        #expect(names(b.work + "/dest") == ["proj"] && !FileManager.default.fileExists(atPath: source))
        // Never into itself.
        let inside = FileCarry(items: [CarryItem(source: .box(alias: "one", path: b.work + "/dest"))], into: .box(alias: "one", path: b.work + "/dest/proj"), move: true, boxes: boxes)
        #expect(await inside.run().failure != nil && inside.steps.isEmpty)
    }
}

/// A stand-in ssh that runs the command here after a pause: long enough to cancel.
@MainActor
func fakeSlowSSH(_ root: URL) throws -> SyncBox {
    let ssh = root.appendingPathComponent("slow-ssh")
    try Data("""
        #!/bin/sh
        while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
        shift; shift
        exec sleep 5
        """.utf8).write(to: ssh)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
    return SyncBox.via(ssh.path, alias: "local", base: root.path)
}
