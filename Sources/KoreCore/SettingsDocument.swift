import Foundation

/// A JSON object read for editing: its members in their order, each kept as the text it was
/// written as, so a write changes only what was edited. Rendered two-space indented, as the CLIs
/// write their own settings.
package struct SettingsDocument: Equatable, Sendable {
    package struct Member: Equatable, Sendable {
        /// The key as written, quotes and escapes included.
        let rawKey: String
        package let key: String
        /// The value's JSON text, as written.
        package var text: String
    }

    package private(set) var members: [Member] = []

    package init() {}

    /// Throws `invalid` when `data` isn't a JSON object; empty data is an empty one.
    package init(parsing data: Data) throws {
        guard !data.allSatisfy({ Self.isSpace($0) }) else { return }
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw Failure.invalid }
        var scanner = Scanner(bytes: Array(data))
        members = try scanner.object()
    }

    package enum Failure: Error, Equatable {
        case invalid
    }

    package var keys: [String] { members.map(\.key) }

    package func text(_ key: String) -> String? { members.last { $0.key == key }?.text }

    /// The member's value; nil when it's missing.
    package func value(_ key: String) -> JSONValue? {
        guard let text = text(key) else { return nil }
        return Self.parse(text)
    }

    package func string(_ key: String) -> String? { value(key)?.string }

    /// A member that is itself an object, for editing (`env`); empty when it's missing or isn't one.
    package func object(_ key: String) -> SettingsDocument {
        guard let text = text(key), let document = try? SettingsDocument(parsing: Data(text.utf8)) else { return SettingsDocument() }
        return document
    }

    /// Sets a member's JSON text: in its place when it's there, else at the end.
    package mutating func set(_ key: String, text: String) {
        if let index = members.lastIndex(where: { $0.key == key }) {
            members[index].text = text
        } else {
            members.append(Member(rawKey: Self.quoted(key), key: key, text: text))
        }
    }

    package mutating func set(_ key: String, string: String) { set(key, text: Self.quoted(string)) }

    package mutating func set(_ key: String, object: SettingsDocument) { set(key, text: object.rendered(depth: 1)) }

    package mutating func remove(_ key: String) { members.removeAll { $0.key == key } }

    package mutating func removeAll(where drop: (String) -> Bool) { members.removeAll { drop($0.key) } }

    /// The document's text: each member on its own line, two spaces deeper than its object.
    package func rendered(depth: Int = 0) -> String {
        guard !members.isEmpty else { return "{}" }
        let pad = String(repeating: "  ", count: depth + 1)
        let lines = members.map { pad + $0.rawKey + ": " + $0.text }
        return "{\n" + lines.joined(separator: ",\n") + "\n" + String(repeating: "  ", count: depth) + "}"
    }

    package var data: Data { Data((rendered() + "\n").utf8) }

    /// A string as JSON text, slashes left as they are.
    package static func quoted(_ string: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func parse(_ text: String) -> JSONValue? { try? JSONValue.parse(Data(text.utf8)) }

    static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 }

    /// Walks an object already known to be valid JSON, cutting it into members.
    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
            // A byte-order mark.
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
        }

        mutating func object() throws -> [Member] {
            skipSpace()
            try expect(UInt8(ascii: "{"))
            var members: [Member] = []
            skipSpace()
            if peek == UInt8(ascii: "}") { return members }
            while true {
                skipSpace()
                let keyStart = index
                try skipString()
                let rawKey = text(keyStart, index)
                guard let key = SettingsDocument.parse(rawKey)?.string else { throw Failure.invalid }
                skipSpace()
                try expect(UInt8(ascii: ":"))
                skipSpace()
                let valueStart = index
                try skipValue()
                members.append(Member(rawKey: rawKey, key: key, text: text(valueStart, index)))
                skipSpace()
                guard let next = peek else { throw Failure.invalid }
                index += 1
                if next == UInt8(ascii: "}") { return members }
                guard next == UInt8(ascii: ",") else { throw Failure.invalid }
            }
        }

        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        func text(_ start: Int, _ end: Int) -> String { String(decoding: bytes[start..<end], as: UTF8.self) }

        mutating func skipSpace() {
            while let byte = peek, SettingsDocument.isSpace(byte) { index += 1 }
        }

        mutating func expect(_ byte: UInt8) throws {
            guard peek == byte else { throw Failure.invalid }
            index += 1
        }

        mutating func skipString() throws {
            try expect(UInt8(ascii: "\""))
            while let byte = peek {
                index += 1
                if byte == UInt8(ascii: "\\") {
                    index += 1
                } else if byte == UInt8(ascii: "\"") {
                    return
                }
            }
            throw Failure.invalid
        }

        mutating func skipValue() throws {
            guard let first = peek else { throw Failure.invalid }
            switch first {
            case UInt8(ascii: "\""):
                try skipString()
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                while let byte = peek {
                    switch byte {
                    case UInt8(ascii: "\""):
                        try skipString()
                        continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["):
                        depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                    default: break
                    }
                    index += 1
                    if depth == 0 { return }
                }
                throw Failure.invalid
            default:
                while let byte = peek, byte != UInt8(ascii: ","), byte != UInt8(ascii: "}"), byte != UInt8(ascii: "]"),
                    !SettingsDocument.isSpace(byte)
                {
                    index += 1
                }
            }
        }
    }
}

/// Writing a settings file the way the CLI would find it: atomically (a temporary file in the same
/// folder, then a rename over it), at mode 0600, after keeping one copy of the file as it was
/// before Kore first wrote it (`<name>.kore-backup`).
package enum SettingsFile {
    package static func read(_ url: URL) throws -> SettingsDocument {
        guard let data = try? Data(contentsOf: url.resolvingSymlinksInPath()) else { return SettingsDocument() }
        return try SettingsDocument(parsing: data)
    }

    package static func backup(of url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".kore-backup")
    }

    package static func write(_ document: SettingsDocument, to url: URL) throws {
        let files = FileManager.default
        let target = url.resolvingSymlinksInPath()
        let folder = target.deletingLastPathComponent()
        try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = backup(of: url)
        if files.fileExists(atPath: target.path), !files.fileExists(atPath: backup.path) {
            try files.copyItem(at: target, to: backup)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        let temporary = folder.appendingPathComponent(".\(target.lastPathComponent).kore-\(UUID().uuidString)")
        guard files.createFile(atPath: temporary.path, contents: document.data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, target.path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? files.removeItem(at: temporary)
            throw error
        }
    }
}
