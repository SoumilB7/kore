import Foundation
import HostClient
import Testing

/// `file.fetch` (the owner, 2026-11-17): one file from an open folder, this Mac's or a box's, into
/// the asker's `.kore/inbox/` through the carry engine; never a secret-looking path, nothing
/// outside the open folders (links followed), no folder, 50 MB at most, and another device's file
/// only at Act device. Each refusal leaves the inbox empty.
@MainActor
@Suite("Arsenal fetch", .serialized)
struct ArsenalFetchTests {
    private func scratch() throws -> String {
        let path = "/tmp/kaf-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: path + "/a/sub", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: path + "/b", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: path + "/other", withIntermediateDirectories: true)
        return path
    }

    private func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: path)) }

    private func names(_ folder: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted() }

    @Test func secretLookingPathsAreRefusedAnywhereInThePath() {
        for path in [
            "/w/.env", "/w/.env.local", "/w/config/server.pem", "/w/tls.key", "/home/me/.ssh/config", "/w/id_ed25519",
            "/home/me/.aws/config", "/w/credentials.json", "/home/me/.netrc", "/Users/me/Library/Keychains/login.keychain-db",
            "/home/me/.gnupg/pubring.kbx",
        ] {
            #expect(ArsenalFetch.secret(path), "\(path)")
        }
        for path in ["/w/schema.sql", "/w/environment.md", "/w/keys.txt", "/w/README.md", "/w/docs/ssh.md"] {
            #expect(!ArsenalFetch.secret(path), "\(path)")
        }
    }

    @Test func aPlaceIsADevicesPathOrOneOnTheAsker() throws {
        let base = FilePlace.mac("/Users/me/app")
        let names = ["mybox": "mybox-alias", "Big Box": "big"]
        #expect(try ArsenalFetch.place("mybox:/srv/app/a.sql", base: base, names: names).get() == .box(alias: "mybox-alias", path: "/srv/app/a.sql"))
        #expect(try ArsenalFetch.place("db/a.sql", base: base, names: names).get() == .mac("/Users/me/app/db/a.sql"))
        #expect(try ArsenalFetch.place("/etc/hosts", base: base, names: names).get() == .mac("/etc/hosts"))
        #expect(try ArsenalFetch.place("mac:/Users/me/x.md", base: .box(alias: "b", path: "/srv"), names: names).get() == .mac("/Users/me/x.md"))
        #expect(ArsenalFetch.place("nobox:/srv/a", base: base, names: names) == .failure(.noDevice("nobox")))
        #expect(ArsenalFetch.normalized("/srv/app/../../etc/passwd") == "/etc/passwd")
    }

    @Test func aMacFileLandsInTheInboxUnderAFreeName() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(root + "/a/schema.sql", "create table users;")
        let inbox = FilePlace.mac(root + "/b/.kore/inbox")
        let first = await ArsenalFetch.run(.mac(root + "/a/schema.sql"), roots: [root + "/a", root + "/b"], into: inbox, boxes: [:])
        #expect(try first.get().path == root + "/b/.kore/inbox/schema.sql")
        let second = await ArsenalFetch.run(.mac(root + "/a/schema.sql"), roots: [root + "/a"], into: inbox, boxes: [:])
        #expect(try second.get().name == "schema 2.sql")
        #expect(names(root + "/b/.kore/inbox") == ["schema 2.sql", "schema.sql"])
        #expect(try String(contentsOfFile: root + "/b/.kore/inbox/schema 2.sql", encoding: .utf8) == "create table users;")
        // A copy: the source stays.
        #expect(FileManager.default.fileExists(atPath: root + "/a/schema.sql"))
    }

    @Test func secretsOutsidersLinksOutFoldersAndBigFilesAreRefused() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(root + "/other/taxes.pdf", "private")
        try write(root + "/a/.env", "KEY=1")
        try FileManager.default.createSymbolicLink(atPath: root + "/a/link.pdf", withDestinationPath: root + "/other/taxes.pdf")
        FileManager.default.createFile(atPath: root + "/a/big.bin", contents: nil)
        let big = try FileHandle(forWritingTo: URL(fileURLWithPath: root + "/a/big.bin"))
        try big.truncate(atOffset: UInt64(ArsenalFetch.cap) + 1)
        try big.close()
        let roots = [root + "/a"]
        let inbox = FilePlace.mac(root + "/b/.kore/inbox")
        func fetch(_ source: FilePlace, into: FilePlace = inbox) async -> ArsenalFetch.Refusal? {
            if case .failure(let refusal) = await ArsenalFetch.run(source, roots: roots, into: into, boxes: [:]) { return refusal }
            return nil
        }
        #expect(await fetch(.mac(root + "/a/.env")) == .secret(".env"))
        #expect(await fetch(.mac(root + "/other/taxes.pdf")) == .outside(root + "/other/taxes.pdf", device: "this Mac"))
        // A link inside the folder that points out of it: followed, then refused.
        #expect(await fetch(.mac(root + "/a/link.pdf")) == .outside(root + "/a/link.pdf", device: "this Mac"))
        #expect(await fetch(.mac(root + "/a/../other/taxes.pdf")) == .outside(root + "/a/../other/taxes.pdf", device: "this Mac"))
        #expect(await fetch(.mac(root + "/a/sub")) == .folder(root + "/a/sub"))
        #expect(await fetch(.mac(root + "/a/none.txt")) == .missing(root + "/a/none.txt"))
        #expect(await fetch(.mac(root + "/a/big.bin")) == .tooBig("big.bin", bytes: ArsenalFetch.cap + 1))
        // Another device's file, below Act device: box to Mac, Mac to box, box to box.
        #expect(await fetch(.mac(root + "/a/sub"), into: .box(alias: "mybox", path: "/srv/w/.kore/inbox")) == .otherDevice)
        #expect(await fetch(.box(alias: "mybox", path: "/srv/w/a.sql")) == .otherDevice)
        #expect(await fetch(.box(alias: "other", path: "/srv/w/a.sql"), into: .box(alias: "mybox", path: "/srv/w/.kore/inbox")) == .otherDevice)
        #expect(ArsenalFetch.Refusal.otherDevice.line == "a file on another device needs Arsenal's Act device tier")
        #expect(ArsenalFetch.Refusal.secret(".env").line == ".env looks like a secret")
        #expect(names(root + "/b").isEmpty)
    }

    /// Across devices, at Act device: a box's file comes to the Mac's inbox through the carry engine
    /// (the box's link for its count, rsync over a stand-in ssh for the bytes), and a Mac's file
    /// goes to a box chat's inbox; a path that climbs out of the box's open folder is refused
    /// before the box is asked. Below Act device, neither goes.
    @Test func aBoxFileComesOverToTheMacsInbox() async throws {
        let rig = try BoxRig()
        let connection = rig.connection()
        connection.retain()
        let mac = "/tmp/kaf-mac-\(UUID().uuidString.prefix(6))"
        defer {
            connection.release()
            rig.finish()
            try? FileManager.default.removeItem(atPath: mac)
        }
        #expect(await until { connection.isOnline })
        try write(rig.folder.path + "/0007_users.sql", "create table users (id int);")
        let boxes = [connection.alias: CarryBox(alias: connection.alias, files: connection, ssh: try fakeSSH(rig.root))]
        let inbox = FilePlace.mac(mac + "/.kore/inbox")
        let source = FilePlace.box(alias: connection.alias, path: rig.folder.path + "/0007_users.sql")
        #expect(await ArsenalFetch.run(source, roots: [rig.folder.path], into: inbox, boxes: boxes) == .failure(.otherDevice))
        #expect(names(mac).isEmpty)
        let landed = await ArsenalFetch.run(source, roots: [rig.folder.path], into: inbox, boxes: boxes, acrossDevices: true)
        #expect(try landed.get() == .mac(mac + "/.kore/inbox/0007_users.sql"))
        #expect(try String(contentsOfFile: mac + "/.kore/inbox/0007_users.sql", encoding: .utf8) == "create table users (id int);")
        // Box to Mac: the Mac's file into the box chat's inbox.
        try write(mac + "/notes.md", "from the mac")
        let boxInbox = FilePlace.box(alias: connection.alias, path: rig.folder.path + "/.kore/inbox")
        #expect(await ArsenalFetch.run(.mac(mac + "/notes.md"), roots: [mac], into: boxInbox, boxes: boxes) == .failure(.otherDevice))
        let up = await ArsenalFetch.run(.mac(mac + "/notes.md"), roots: [mac], into: boxInbox, boxes: boxes, acrossDevices: true)
        #expect(try up.get() == .box(alias: connection.alias, path: rig.folder.path + "/.kore/inbox/notes.md"))
        #expect(try String(contentsOfFile: rig.folder.path + "/.kore/inbox/notes.md", encoding: .utf8) == "from the mac")
        let climbed = await ArsenalFetch.run(
            .box(alias: connection.alias, path: rig.folder.path + "/../state/x"), roots: [rig.folder.path], into: inbox, boxes: boxes, acrossDevices: true)
        #expect(climbed == .failure(.outside(rig.folder.path + "/../state/x", device: FilePlace.box(alias: connection.alias, path: "/").device)))
    }
}
