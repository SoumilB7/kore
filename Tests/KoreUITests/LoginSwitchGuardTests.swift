import Foundation
import Testing

/// A CLI moves to another login only when the owner picks it: the switch takes a `LoginPick`,
/// which only the Account popup's rows can make, and nothing else in the app makes a login
/// active. Storylines set their own fixtures up and are not part of the app.
@Suite("Login switches are picked by hand")
struct LoginSwitchGuardTests {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    /// The app's Swift files (storylines left out) that contain `text`, by path under Sources.
    private func files(containing text: String) throws -> Set<String> {
        let root = Self.sources.standardizedFileURL.path
        var found: Set<String> = []
        let walker = try #require(FileManager.default.enumerator(atPath: root))
        for case let path as String in walker where path.hasSuffix(".swift") && !path.contains("Storylines") {
            let source = try String(contentsOfFile: root + "/" + path, encoding: .utf8)
            if source.contains(text) { found.insert(path) }
        }
        return found
    }

    @Test func onlyTheAccountPopupMakesAPick() throws {
        #expect(try files(containing: "LoginPick()") == ["KoreUI/Chat/Composer/AccountPopup.swift"])
        let popup = try String(contentsOf: Self.sources.appendingPathComponent("KoreUI/Chat/Composer/AccountPopup.swift"), encoding: .utf8)
        #expect(popup.contains("struct LoginPick {\n    fileprivate init() {}\n}"))
    }

    @Test func onlyAPickedSwitchOrALandedSignInMakesALoginActive() throws {
        let store = "KoreUI/Account/AccountStore.swift"
        #expect(try files(containing: "CLIProfiles.activate(") == [store])
        #expect(try files(containing: "CLIProfiles.adopt(") == [store])
        let source = try String(contentsOf: Self.sources.appendingPathComponent(store), encoding: .utf8)
        #expect(source.components(separatedBy: "CLIProfiles.activate(").count == 2)
        #expect(source.contains("func switchLogin(_ provider: String, to id: String?, _ pick: LoginPick)"))
    }
}
