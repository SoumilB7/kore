import Foundation
import Testing
@testable import KoreCore

@Suite("folder moves")
struct FolderIdentityTests {
    @Test func pathsUnderTheFolderMoveWithIt() {
        #expect(remapped("/a/proj/src/x.swift", from: "/a/proj", to: "/a/proj2") == "/a/proj2/src/x.swift")
        #expect(remapped("/a/proj", from: "/a/proj", to: "/a/proj2") == "/a/proj2")
        #expect(remapped("/a/proj/", from: "/a/proj/", to: "/b/") == "/b")
    }

    @Test func pathsOutsideStayPut() {
        #expect(remapped("/a/project/x", from: "/a/proj", to: "/a/new") == nil)
        #expect(remapped("/b/x", from: "/a/proj", to: "/a/new") == nil)
    }

    @Test func identityFollowsARenameAndLosesADelete() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("kore-ident-\(UUID().uuidString)")
        let folder = base.appendingPathComponent("one")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let identity = FolderIdentity(folder)
        let moved = base.appendingPathComponent("two")
        try FileManager.default.moveItem(at: folder, to: moved)
        #expect(identity.current().map { realPath($0.path) } == realPath(moved.path))
        try FileManager.default.removeItem(at: moved)
        #expect(identity.current() == nil)
    }
}
