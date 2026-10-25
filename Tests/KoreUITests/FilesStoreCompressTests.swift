import Foundation
import KoreCore
import Testing

@testable import KoreUI

/// Compress, as Finder does it, on a temp folder.
@MainActor
@Suite("Files: compress", .serialized)
final class FilesStoreCompressTests {
    let root: String
    let store: FilesStore

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kore-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("docs/guides"), withIntermediateDirectories: true)
        root = realPath(url.path)
        try "notes".write(toFile: root + "/docs/notes.md", atomically: true, encoding: .utf8)
        try "readme".write(toFile: root + "/readme.md", atomically: true, encoding: .utf8)
        store = FilesStore(folder: url)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func size(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: root + "/" + path))?[.size] as? Int) ?? 0
    }

    private func entries(_ zip: String) throws -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", root + "/" + zip]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
    }

    @Test func aFolderZipsBesideItThenNumbersTheNext() async throws {
        #expect(await store.compress([root + "/docs"]) == nil)
        #expect(size("docs.zip") > 0)
        #expect(try entries("docs.zip").contains("docs/notes.md"))
        #expect(store.selection == root + "/docs.zip")
        #expect(await store.compress([root + "/docs"]) == nil)
        #expect(size("docs 2.zip") > 0)
        #expect(await store.compress([root + "/readme.md"]) == nil)
        #expect(size("readme.md.zip") > 0)
    }

    @Test func severalMakeAnArchiveInTheirCommonFolder() async throws {
        #expect(await store.compress([root + "/docs/guides", root + "/readme.md"]) == nil)
        #expect(try entries("Archive.zip").isSuperset(of: ["guides/", "readme.md"]))
    }

    @Test func aMissingItemFailsAndLeavesNothing() async {
        #expect(await store.compress([root + "/gone"]) != nil)
        #expect(!FileManager.default.fileExists(atPath: root + "/gone.zip"))
    }
}
