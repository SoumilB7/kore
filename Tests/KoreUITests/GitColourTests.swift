import AppKit
import SwiftUI
import Testing

@testable import KoreCore
@testable import KoreUI

/// Porcelain states reach the existing semantic palette, including inherited folder states.
@MainActor @Suite("Git colours")
struct GitColourTests {
    private enum Hue { case green, blue, red }

    private func rgb(_ color: Color) throws -> SIMD3<Double> {
        let color = try #require(NSColor(color).usingColorSpace(.sRGB))
        return SIMD3(Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
    }

    private func hue(_ state: GitStatus.State, is expected: Hue) throws -> Bool {
        let color = try rgb(Theme.Git.color(state))
        switch expected {
        case .green: return color.y > color.x && color.y > color.z
        case .blue: return color.z > color.x && color.z > color.y
        case .red: return color.x > color.y && color.x > color.z
        }
    }

    @Test func addedUntrackedModifiedAndDeletedKeepTheirSemanticHues() throws {
        let status = GitStatus.parse("A  added.swift\0?? scratch/\0 M modified.swift\0 D removed.swift\0", root: "/repo")
        let paths: [(String, Hue)] = [
            ("added.swift", .green), ("scratch", .green), ("scratch/nested/file.swift", .green),
            ("modified.swift", .blue), ("removed.swift", .red),
        ]
        for (path, expected) in paths {
            let state = try #require(status.state(of: "/repo/" + path))
            #expect(try hue(state, is: expected), "Wrong Git hue for \(path)")
        }
        #expect(status.state(of: "/repo/clean.swift") == nil)
    }

    @Test func mixedFoldersTakeTheirStrongestStateWithoutRecolouringTheirChildren() throws {
        let status = GitStatus.parse("A  mixed/new.swift\0 M mixed/changed.swift\0 D mixed/removed.swift\0", root: "/repo")
        let folder = try #require(status.state(of: "/repo/mixed"))
        #expect(folder == .deleted)
        #expect(try hue(folder, is: .red))
        let added = try #require(status.state(of: "/repo/mixed/new.swift"))
        let modified = try #require(status.state(of: "/repo/mixed/changed.swift"))
        let deleted = try #require(status.state(of: "/repo/mixed/removed.swift"))
        #expect(try hue(added, is: .green))
        #expect(try hue(modified, is: .blue))
        #expect(try hue(deleted, is: .red))
    }

    @Test func ignoredFoldersStayMutedWithoutMarkingTheirCleanParent() throws {
        let status = GitStatus.parse("!! build/\0", root: "/repo")
        let expected = try rgb(Theme.tertiary)
        for path in ["/repo/build", "/repo/build/cache/object.o"] {
            let state = try #require(status.state(of: path))
            #expect(state == .ignored)
            #expect(Theme.Git.letter(state) == nil)
            let color = try rgb(Theme.Git.color(state))
            #expect(color == expected)
        }
        #expect(status.state(of: "/repo") == nil)
    }

    @Test func recordedChangesUseTheSameHuesAsCorrespondingWorkTreeStates() throws {
        let cases: [(String, String, FileChange.Kind)] = [
            ("A  new.swift\0", "new.swift", .add),
            (" M edited.swift\0", "edited.swift", .update),
            (" D removed.swift\0", "removed.swift", .delete),
            ("R  renamed.swift\0previous.swift\0", "renamed.swift", .move(from: "/repo/previous.swift")),
        ]
        for (porcelain, path, kind) in cases {
            let status = GitStatus.parse(porcelain, root: "/repo")
            let state = try #require(status.state(of: "/repo/" + path))
            let current = try rgb(Theme.Git.color(state))
            let recorded = try rgb(Theme.Git.color(kind))
            #expect(recorded == current, "Recorded and live Git hues disagree for \(path)")
        }
    }
}
