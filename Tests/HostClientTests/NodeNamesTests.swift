import Foundation
import KoreTrust
import LinkProtocol
import Testing

@testable import HostClient

/// A box rekeyed to its KoreNet id is still "mybox" in every word Kore says: the id is a key, never
/// a name.
@MainActor
@Suite("box names after a rekey", .serialized)
struct NodeNamesTests {
    /// Every place a box's key is put into words, in the Mac's sources: each goes through
    /// `NodeNames.name`. Keys (defaults, `box:` workspace keys, usage `<box>/<chat>`) don't count.
    @Test func everyStringBuiltFromABoxKeyUsesItsName() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let keyFiles: Set<String> = ["NodeMigration.swift", "NodeDirectory.swift", "HostRoute.swift"]
        let rules: [(String, NSRegularExpression)] = try [
            ("interpolated key", NSRegularExpression(pattern: #"\\\((?:[\w$]+(?:\??\.\w+)*\??\.)?alias\)"#)),
            ("interpolated optional key", NSRegularExpression(pattern: #"\\\([\w$.?]*alias \?\?"#)),
            ("key shown as text", NSRegularExpression(pattern: #"\b(?:Text|Button|OptionItem)\((?:[\w$]+\.)*alias\b"#)),
            ("key joined to words", NSRegularExpression(pattern: #"\b(?:[\w$]+\.)*alias \+ "[ ·]"#)),
            // `"box:" + alias`: a workspace or cache key, not words.
            ("words joined to key", NSRegularExpression(pattern: #""(?!box:")[^"]*[ ·:]" \+ (?:[\w$]+\.)*alias\b"#)),
        ]
        var found: [String] = []
        var scanned = 0
        for folder in ["HostClient", "KoreUI", "KoreLink"] {
            let files = FileManager.default.enumerator(at: sources.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            while let url = files?.nextObject() as? URL {
                guard url.pathExtension == "swift", !keyFiles.contains(url.lastPathComponent) else { continue }
                scanned += 1
                for (number, line) in try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let text = String(line)
                    guard !text.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                    for (rule, regex) in rules where regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                        found.append("\(folder)/\(url.lastPathComponent):\(number + 1) \(rule): \(text.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
        #expect(scanned > 100)
        #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
    }

    @Test func aRekeyedBoxIsCalledByItsAliasInWords() throws {
        let defaults = UserDefaults(suiteName: "kore-names-\(UUID().uuidString)")!
        let directory = NodeDirectory(defaults: defaults)
        let before = NodeDirectory.shared
        NodeDirectory.shared = directory
        defer { NodeDirectory.shared = before }
        let device = UUID()
        let id = device.uuidString.lowercased()
        directory.upsert(.init(device: device, name: "box-1.local", ssh: "mybox", nodeKey: nil, identityKey: Data([1]), enrolled: true, rekeyed: true))
        func clean(_ words: String, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(words.contains("mybox") && !words.contains(id) && !words.lowercased().contains(id.prefix(8)), "\(words)", sourceLocation: sourceLocation)
        }
        // The key stays the id; the words, the alias.
        let connection = HostConnection(alias: id, cache: HostCache(alias: id, root: FileManager.default.temporaryDirectory)) { FakeHost.pair().client }
        #expect(connection.alias == id && connection.name == "mybox" && connection.sshAlias == "mybox")
        clean(HostConnection.Refused.auth.line(connection.name))
        for code in [ResultCode.busy, .goneChat, .goneFolder, .deniedControl, .tooLarge, .unknown] {
            clean(HostRefusal(LinkMessage.Result(id: "c1", ok: false, code: code, message: nil), alias: id).message)
        }
        clean(FilePlace.box(alias: id, path: "/w").device)
        #expect(BoxAddress(id)?.host == "mybox")
        // A box this Mac never heard of keeps whatever it's keyed by; a plain alias is its own name.
        #expect(NodeNames.name("other-box") == "other-box")
        // Before its alias was known (no SSH alias), the name the box gave.
        let phone = UUID()
        directory.upsert(.init(device: phone, name: "box-2", ssh: nil, nodeKey: nil, identityKey: Data([2])))
        #expect(NodeNames.name(phone.uuidString.lowercased()) == "box-2")
    }
}
