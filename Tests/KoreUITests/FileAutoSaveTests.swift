import AppKit
import KoreCore
import Testing

@testable import KoreUI

@MainActor @Suite("Files: automatic save", .serialized)
struct FileAutoSaveTests {
    private enum Timeout: Error { case waiting }

    @MainActor private final class Delay {
        var waits: [CheckedContinuation<Void, Never>] = []
        var calls = 0
        func pause(_ delay: Duration) async throws {
            calls += 1
            await withCheckedContinuation { waits.append($0) }
            try Task.checkCancellation()
        }
        func fire() {
            let ready = waits
            waits = []
            ready.forEach { $0.resume() }
        }
    }

    @MainActor private final class Fixture {
        let folder: URL
        let url: URL
        let delay: Delay
        let setting: FileAutoSave
        let document: FileDocument
        init(_ data: Data = Data("first\n".utf8)) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("kore-autosave-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            url = folder.appendingPathComponent("notes.txt")
            try data.write(to: url)
            let delay = Delay()
            self.delay = delay
            let setting = FileAutoSave(defaults: nil, pause: { try await delay.pause($0) })
            self.setting = setting
            document = FileDocument(url: url, autoSave: setting)
            document.load()
        }
        func edit(_ text: String) {
            document.storage.replaceCharacters(in: NSRange(location: 0, length: document.storage.length), with: text)
            document.edited()
        }
        func read() throws -> Data { try Data(contentsOf: url) }
        func finish() {
            document.closeAutoSave()
            delay.fire()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func until(_ check: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !check() {
            guard ContinuousClock.now < end else { throw Timeout.waiting }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func defaultOnAndAStoredChoiceSurvivesRelaunch() throws {
        let name = "kore-autosave-setting-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let setting = FileAutoSave(defaults: defaults)
        #expect(setting.isEnabled)
        setting.isEnabled = false
        #expect(!FileAutoSave(defaults: defaults).isEnabled)
        setting.isEnabled = true
        #expect(FileAutoSave(defaults: defaults).isEnabled)
    }

    @Test func onlyTheTrailingEditWritesAndThenNothingRemainsScheduled() async throws {
        let f = try Fixture()
        defer { f.finish() }
        f.edit("one\n")
        try await until { f.delay.calls == 1 }
        f.edit("two\n")
        try await until { f.delay.calls == 2 }
        #expect(try f.read() == Data("first\n".utf8))
        f.delay.fire()
        try await until { !f.document.isDirty }
        #expect(try f.read() == Data("two\n".utf8))
        #expect(f.document.notice == nil)
        #expect(f.delay.calls == 2 && f.delay.waits.isEmpty)
        f.document.diskChanged()
        #expect(f.document.notice == nil && !f.document.isDirty)
    }

    /// A new empty file typed into: each automatic save is Kore's own, and neither the next
    /// save nor the disk event for the last one raises the changed-on-disk notice. A real change
    /// from outside with no edits still reloads in place.
    @Test func ownSavesNeverReadAsAChangeOnDisk() async throws {
        let f = try Fixture(Data())
        defer { f.finish() }
        func turn() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        f.edit("# Black Eye")
        try await until { f.delay.calls == 1 }
        f.delay.fire()
        try await until { !f.document.isDirty }
        turn()
        f.edit("# Black Eye\n")
        // The disk event for the first save lands after the next keystroke.
        f.document.diskChanged()
        #expect(f.document.notice == nil && f.document.isDirty)
        try await until { f.delay.calls == 2 }
        f.delay.fire()
        try await until { !f.document.isDirty || f.document.notice != nil }
        #expect(f.document.notice == nil)
        #expect(try f.read() == Data("# Black Eye\n".utf8))
        turn()
        f.edit("# Black Eye\none")
        try await until { f.delay.calls == 3 }
        f.delay.fire()
        try await until { !f.document.isDirty || f.document.notice != nil }
        #expect(f.document.notice == nil)
        #expect(try f.read() == Data("# Black Eye\none".utf8))
        f.document.diskChanged()
        #expect(f.document.notice == nil && !f.document.isDirty)
        try Data("from outside\n".utf8).write(to: f.url)
        f.document.diskChanged()
        #expect(f.document.notice == nil && !f.document.isDirty)
        #expect(f.document.storage.string == "from outside\n")
    }

    @Test func undoAndDisablingCancelDelayedWritesButEnablingSchedulesDirtyFiles() async throws {
        let f = try Fixture()
        defer { f.finish() }
        f.edit("new\n")
        try await until { f.delay.calls == 1 }
        f.edit("first\n")
        #expect(!f.document.isDirty)
        f.delay.fire()
        try await Task.sleep(for: .milliseconds(10))
        #expect(try f.read() == Data("first\n".utf8))
        f.edit("new\n")
        try await until { f.delay.calls == 2 }
        f.setting.isEnabled = false
        f.delay.fire()
        try await Task.sleep(for: .milliseconds(10))
        #expect(f.document.isDirty)
        #expect(try f.read() == Data("first\n".utf8))
        f.setting.isEnabled = true
        try await until { f.delay.calls == 3 }
        f.delay.fire()
        try await until { !f.document.isDirty }
        #expect(try f.read() == Data("new\n".utf8))
    }

    @Test func externalChangesCannotBeOverwrittenEvenWithTheSameStamp() async throws {
        let f = try Fixture()
        defer { f.finish() }
        // A whole second, so setting it again later gives the very same stamp.
        let second = Date(timeIntervalSinceReferenceDate: floor(Date().timeIntervalSinceReferenceDate) - 60)
        try FileManager.default.setAttributes([.modificationDate: second], ofItemAtPath: f.url.path)
        f.document.diskChanged()
        f.edit("mine\n")
        try await until { f.delay.calls == 1 }
        let stamp = try #require(TextFile.Stamp.of(f.url))
        try Data("other\n".utf8).write(to: f.url)
        try FileManager.default.setAttributes([.modificationDate: second], ofItemAtPath: f.url.path)
        #expect(TextFile.Stamp.of(f.url) == stamp)
        f.delay.fire()
        try await until { f.document.notice == .changed }
        #expect(f.document.isDirty)
        #expect(try f.read() == Data("other\n".utf8))
        f.edit("mine again\n")
        #expect(!f.document.flushAutoSave())
        #expect(try f.read() == Data("other\n".utf8))
        f.document.keepMine()
        try await until { f.delay.calls == 2 }
        f.delay.fire()
        try await until { !f.document.isDirty }
        #expect(try f.read() == Data("mine again\n".utf8))
    }

    @Test func aDeletedFileIsNotResurrectedWithoutAUserSave() async throws {
        let f = try Fixture()
        defer { f.finish() }
        f.edit("mine\n")
        try await until { f.delay.calls == 1 }
        try FileManager.default.removeItem(at: f.url)
        f.delay.fire()
        try await until { f.document.notice == .deleted }
        #expect(!FileManager.default.fileExists(atPath: f.url.path))
        #expect(!f.document.flushAutoSave())
        #expect(!FileManager.default.fileExists(atPath: f.url.path))
    }

    @Test func readOnlyFailuresRemainDirtyAndRetryOnlyOnAnotherEdit() async throws {
        let f = try Fixture()
        defer { f.finish() }
        f.edit("mine\n")
        try await until { f.delay.calls == 1 }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: f.url.path)
        f.delay.fire()
        try await until { f.document.notice != nil }
        guard case .saveFailed = f.document.notice else { Issue.record("Expected a nonmodal save error"); return }
        #expect(f.document.isDirty && f.delay.waits.isEmpty)
        f.setting.isEnabled = false
        f.setting.isEnabled = true
        try await Task.sleep(for: .milliseconds(10))
        #expect(f.delay.calls == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.url.path)
        f.edit("changed again\n")
        try await until { f.delay.calls == 2 }
        f.delay.fire()
        try await until { !f.document.isDirty }
        #expect(f.document.notice == nil)
        #expect(try f.read() == Data("changed again\n".utf8))
    }

    @Test func closeDiscardMoveManualSaveAndFlushDoNotLeaveStaleWrites() async throws {
        let f = try Fixture()
        defer { f.finish() }
        f.edit("discard\n")
        try await until { f.delay.calls == 1 }
        f.document.closeAutoSave()
        f.delay.fire()
        try await Task.sleep(for: .milliseconds(10))
        #expect(try f.read() == Data("first\n".utf8))
        f.document.resumeAutoSave()
        try await until { f.delay.calls == 2 }
        let moved = f.folder.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: f.url, to: moved)
        f.document.moved(to: moved)
        try await until { f.delay.calls == 3 }
        #expect(f.document.save())
        f.delay.fire()
        try await Task.sleep(for: .milliseconds(10))
        #expect(!FileManager.default.fileExists(atPath: f.url.path))
        #expect(try Data(contentsOf: moved) == Data("discard\n".utf8))
        f.edit("flushed\n")
        #expect(f.document.flushAutoSave())
        #expect(!f.document.isDirty)
        #expect(try Data(contentsOf: moved) == Data("flushed\n".utf8))
    }

    @Test func automaticSavePreservesEncodingBomAndLineEndings() async throws {
        for utf16 in [false, true] {
            let source = utf16 ? try #require("first\r\n".data(using: .utf16)) : Data([0xEF, 0xBB, 0xBF] + Array("first\r\n".utf8))
            let f = try Fixture(source)
            f.edit("next\nline\n")
            try await until { f.delay.calls == 1 }
            f.delay.fire()
            try await until { !f.document.isDirty }
            let saved = try f.read()
            if utf16 {
                #expect(String(data: saved, encoding: .utf16) == "next\r\nline\r\n")
            } else {
                #expect(saved == Data([0xEF, 0xBB, 0xBF] + Array("next\r\nline\r\n".utf8)))
            }
            f.finish()
        }
    }

    @Test func lineEndingChangeSavesWithoutTypingAndReloadCancelsEdits() async throws {
        let f = try Fixture()
        defer { f.finish() }
        f.document.setLineEnding(.crlf)
        try await until { f.delay.calls == 1 }
        f.delay.fire()
        try await until { !f.document.isDirty }
        #expect(try f.read() == Data("first\r\n".utf8))
        f.edit("discard\n")
        try await until { f.delay.calls == 2 }
        f.document.reloadInPlace()
        f.delay.fire()
        try await Task.sleep(for: .milliseconds(10))
        #expect(f.document.storage.string == "first\n")
        #expect(try f.read() == Data("first\r\n".utf8))
    }
}
