import Foundation
import Testing

@testable import KoreCore

@Suite(.serialized) struct CLIProfilesTests {
    @Test func anAddedLoginKeepsItsOwnLoginAndSharesTheRest() throws {
        let files = FileManager.default
        let base = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let main = base.appendingPathComponent("main", isDirectory: true)
        try files.createDirectory(at: main.appendingPathComponent("projects"), withIntermediateDirectories: true)
        for name in ["settings.json", ".credentials.json", "config.json"] { try Data("{}".utf8).write(to: main.appendingPathComponent(name)) }
        CLIProfiles.root.value = base.appendingPathComponent("accounts")
        CLIProfiles.mains.value = ["claude": main]
        CLIProfiles.reload()
        defer {
            CLIProfiles.root.value = nil
            CLIProfiles.mains.value = [:]
            CLIProfiles.reload()
            try? files.removeItem(at: base)
        }

        let id = try CLIProfiles.prepare("claude")
        let dir = CLIProfiles.folder("claude", id)
        #expect(try files.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("projects").path) == main.appendingPathComponent("projects").path)
        #expect(try files.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("settings.json").path) == main.appendingPathComponent("settings.json").path)
        #expect(!files.fileExists(atPath: dir.appendingPathComponent(".credentials.json").path))
        #expect(!files.fileExists(atPath: dir.appendingPathComponent("config.json").path))
        // Prepared, it's neither listed nor active; pinned, a task's CLIs run in it.
        #expect(CLIProfiles.added("claude").isEmpty)
        #expect(CLIProfiles.overrides("claude").isEmpty)
        CLIProfiles.$pinned.withValue(CLIProfiles.Pin(cli: "claude", id: id)) {
            #expect(CLIProfiles.overrides("claude") == ["CLAUDE_CONFIG_DIR": dir.path])
            #expect(CLIProfiles.overrides("codex").isEmpty)
        }

        CLIProfiles.adopt("claude", id, email: "b@x.com")
        #expect(CLIProfiles.overrides("claude") == ["CLAUDE_CONFIG_DIR": dir.path])
        // What main gains later is linked at the next switch.
        try files.createDirectory(at: main.appendingPathComponent("skills"), withIntermediateDirectories: true)
        CLIProfiles.activate("claude", nil)
        #expect(CLIProfiles.overrides("claude").isEmpty)
        #expect(CLIProfiles.note("claude", email: "a@x.com"))
        #expect(!CLIProfiles.note("claude", email: "a@x.com"))
        CLIProfiles.activate("claude", id)
        #expect(files.fileExists(atPath: dir.appendingPathComponent("skills").path))

        // Kept on disk: a new read finds it.
        CLIProfiles.reload()
        #expect(CLIProfiles.added("claude").map(\.email) == ["b@x.com"])
        #expect(CLIProfiles.mainEmail("claude") == "a@x.com")
        #expect(CLIProfiles.active("claude") == id)

        CLIProfiles.remove("claude", id)
        #expect(CLIProfiles.active("claude") == nil)
        #expect(CLIProfiles.added("claude").isEmpty)
        #expect(!files.fileExists(atPath: dir.path))
    }

    @Test func aNewCodexLoginStartsWithMainsThreadsAndStraysGo() throws {
        let files = FileManager.default
        let base = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let main = base.appendingPathComponent("main", isDirectory: true)
        try files.createDirectory(at: main, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: main.appendingPathComponent("models_cache.json"))
        let db = main.appendingPathComponent("state_5.sqlite").path
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        make.arguments = [db, "create table threads(id text); insert into threads values('t1');"]
        try make.run()
        make.waitUntilExit()
        CLIProfiles.root.value = base.appendingPathComponent("accounts")
        CLIProfiles.mains.value = ["codex": main]
        CLIProfiles.reload()
        defer {
            CLIProfiles.root.value = nil
            CLIProfiles.mains.value = [:]
            CLIProfiles.reload()
            try? files.removeItem(at: base)
        }

        let id = try CLIProfiles.prepare("codex")
        let dir = CLIProfiles.folder("codex", id)
        let copy = Data(try Data(contentsOf: dir.appendingPathComponent("state_5.sqlite")))
        #expect(copy.starts(with: Data("SQLite format 3".utf8)))
        #expect((try? files.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("state_5.sqlite").path)) == nil)
        #expect(!files.fileExists(atPath: dir.appendingPathComponent("models_cache.json").path))
        CLIProfiles.adopt("codex", id, email: "b@x.com")

        // A folder no longer listed goes; a listed one stays.
        let stray = try CLIProfiles.prepare("codex")
        CLIProfiles.sweep()
        #expect(!files.fileExists(atPath: CLIProfiles.folder("codex", stray).path))
        #expect(files.fileExists(atPath: dir.path))
    }
}
