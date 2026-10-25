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

    /// Each login keeps the organisation (or plan) it was read in beside its email, main's too; a
    /// new email drops the old one's. Main can be pinned while another login is active, and each
    /// login's files are found whichever is.
    @Test func eachLoginKeepsItsWorkspaceAndMainCanBePinned() throws {
        let files = FileManager.default
        let base = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let main = base.appendingPathComponent("main", isDirectory: true)
        try files.createDirectory(at: main, withIntermediateDirectories: true)
        CLIProfiles.root.value = base.appendingPathComponent("accounts")
        CLIProfiles.mains.value = ["claude": main]
        CLIProfiles.reload()
        defer {
            CLIProfiles.root.value = nil
            CLIProfiles.mains.value = [:]
            CLIProfiles.reload()
            try? files.removeItem(at: base)
        }

        #expect(CLIProfiles.note("claude", email: "a@x.com", workspace: "Personal"))
        let id = try CLIProfiles.prepare("claude")
        CLIProfiles.adopt("claude", id, email: "b@x.com", workspace: "Acme")
        #expect(CLIProfiles.added("claude").map(\.workspace) == ["Acme"])
        #expect(CLIProfiles.mainWorkspace("claude") == "Personal")
        // Main read while another login is active, in its own folder.
        #expect(!CLIProfiles.note("claude", login: nil, email: "a@x.com", workspace: nil))
        #expect(CLIProfiles.mainWorkspace("claude") == "Personal")
        #expect(CLIProfiles.note("claude", login: nil, email: "c@x.com", workspace: nil))
        #expect(CLIProfiles.mainWorkspace("claude") == nil)
        #expect(CLIProfiles.note("claude", login: id, email: "b@x.com", workspace: "Other"))
        CLIProfiles.$pinned.withValue(CLIProfiles.Pin(cli: "claude", id: nil)) {
            #expect(CLIProfiles.overrides("claude").isEmpty)
        }
        #expect(CLIProfiles.overrides("claude") == ["CLAUDE_CONFIG_DIR": CLIProfiles.folder("claude", id).path])
        #expect(CLIProfiles.environment("claude", login: id)["CLAUDE_CONFIG_DIR"] == CLIProfiles.folder("claude", id).path)
        #expect(CLIProfiles.environment("claude", login: nil)["CLAUDE_CONFIG_DIR"] == ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"])

        CLIProfiles.reload()
        #expect(CLIProfiles.added("claude").map(\.workspace) == ["Other"])
        #expect(CLIProfiles.mainEmail("claude") == "c@x.com")

        // A list saved before workspaces still reads.
        let old = #"{"active":{},"added":{"claude":[{"id":"\#(id)","email":"b@x.com"}]},"mainEmail":{"claude":"a@x.com"}}"#
        try Data(old.utf8).write(to: base.appendingPathComponent("accounts/accounts.json"))
        CLIProfiles.reload()
        #expect(CLIProfiles.added("claude").map(\.email) == ["b@x.com"])
        #expect(CLIProfiles.added("claude").first?.workspace == nil)
        #expect(CLIProfiles.mainWorkspace("claude") == nil)
    }
}

extension CLIProfilesTests {
    private func withRepairProfiles(_ check: (URL, URL) throws -> Void) throws {
        let files = FileManager.default
        let base = files.temporaryDirectory.appendingPathComponent("login-links-\(UUID().uuidString)", isDirectory: true)
        let main = base.appendingPathComponent("main", isDirectory: true)
        try files.createDirectory(at: main.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: main.appendingPathComponent("settings.json"))
        CLIProfiles.root.value = base.appendingPathComponent("accounts")
        CLIProfiles.mains.value = ["claude": main]
        CLIProfiles.reload()
        defer {
            CLIProfiles.root.value = nil
            CLIProfiles.mains.value = [:]
            CLIProfiles.reload()
            try? files.removeItem(at: base)
        }
        try check(base, main)
    }

    @Test func adoptingAFinishedLoginRepairsTheHistoryLinksItRemoved() throws {
        try withRepairProfiles { _, main in
            let id = try CLIProfiles.prepare("claude")
            let dir = CLIProfiles.folder("claude", id)
            for name in ["projects", "settings.json"] { try FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
            let auth = Data("login-owned-credential".utf8)
            try auth.write(to: dir.appendingPathComponent(".credentials.json"))
            CLIProfiles.adopt("claude", id, email: "new@example.test")
            for name in ["projects", "settings.json"] {
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dir.appendingPathComponent(name).path) == main.appendingPathComponent(name).path)
            }
            #expect(try Data(contentsOf: dir.appendingPathComponent(".credentials.json")) == auth)
        }
    }

    @Test func launchesRepairTheSelectedLoginAndRespectPinnedMainWithoutTouchingAuth() throws {
        try withRepairProfiles { _, main in
            let first = try CLIProfiles.prepare("claude"), second = try CLIProfiles.prepare("claude")
            CLIProfiles.adopt("claude", first, email: "first@example.test")
            let firstProjects = CLIProfiles.folder("claude", first).appendingPathComponent("projects")
            let secondProjects = CLIProfiles.folder("claude", second).appendingPathComponent("projects")
            try FileManager.default.removeItem(at: firstProjects)
            try FileManager.default.removeItem(at: secondProjects)
            try CLIProfiles.$pinned.withValue(CLIProfiles.Pin(cli: "claude", id: nil)) {
                try CLIProfiles.repairForLaunch("claude")
            }
            #expect(!FileManager.default.fileExists(atPath: firstProjects.path))
            try CLIProfiles.$pinned.withValue(CLIProfiles.Pin(cli: "claude", id: second)) {
                try CLIProfiles.repairForLaunch("claude")
            }
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: secondProjects.path) == main.appendingPathComponent("projects").path)
            #expect(!FileManager.default.fileExists(atPath: firstProjects.path))
            try CLIProfiles.repairForLaunch("claude")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: firstProjects.path) == main.appendingPathComponent("projects").path)
        }
    }

    @Test func repairPreservesExistingLocalDataAndRefusesAnUnrepairableHistoryLink() throws {
        try withRepairProfiles { base, _ in
            let id = try CLIProfiles.prepare("claude")
            CLIProfiles.adopt("claude", id, email: "new@example.test")
            let dir = CLIProfiles.folder("claude", id)
            let projects = dir.appendingPathComponent("projects")
            try FileManager.default.removeItem(at: projects)
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
            let local = projects.appendingPathComponent("local-session.jsonl")
            try Data("local history".utf8).write(to: local)
            try FileManager.default.removeItem(at: dir.appendingPathComponent("settings.json"))
            try CLIProfiles.repairForLaunch("claude")
            #expect(try Data(contentsOf: local) == Data("local history".utf8))
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: projects.path)) == nil)
            try FileManager.default.removeItem(at: projects)
            let destination = base.appendingPathComponent("missing-projects")
            try FileManager.default.createSymbolicLink(at: projects, withDestinationURL: destination)
            #expect(throws: CLIProfiles.LaunchFailure.self) { try CLIProfiles.repairForLaunch("claude") }
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: projects.path) == destination.path)
        }
    }
}
