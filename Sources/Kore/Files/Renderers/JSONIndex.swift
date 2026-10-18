import Foundation

/// A JSON (or JSONL) file as one flat array of nodes in document order, each pointing back into
/// the file's bytes: a container's children follow it, and `end` is where its subtree stops. No
/// value is decoded until it's drawn or copied, so a 10 MB file costs its bytes plus 32 bytes a
/// value.
final class JSONIndex: Sendable {
    enum Kind: UInt8, Sendable {
        case object, array, string, number, bool, null
    }

    struct Node: Sendable {
        let kind: Kind
        /// The key's bytes without quotes (objects' members); length 0 and start 0 otherwise.
        let keyStart: UInt32
        let keyLength: UInt32
        /// The value's bytes: a string without its quotes; a container from its bracket to its
        /// closing bracket.
        let valueStart: UInt32
        let valueLength: UInt32
        /// Children (containers).
        let count: UInt32
        /// The index past this node's subtree.
        let end: UInt32
        /// The parent's index; `UInt32.max` for a root.
        let parent: UInt32

        var isContainer: Bool { kind == .object || kind == .array }
        var hasKey: Bool { keyLength > 0 || keyStart > 0 }
    }

    struct Failure: Error, Sendable {
        let message: String
        /// 1-based.
        let line: Int
    }

    let data: Data
    let nodes: [Node]
    /// The roots' indexes: one for JSON, one a line for JSONL.
    let roots: [UInt32]
    /// JSONL: each root's 1-based line.
    let rootLines: [Int32]

    private init(data: Data, nodes: [Node], roots: [UInt32], rootLines: [Int32]) {
        self.data = data
        self.nodes = nodes
        self.roots = roots
        self.rootLines = rootLines
    }

    // MARK: - Reading values

    func key(_ node: Node) -> String { string(start: node.keyStart, length: node.keyLength, limit: .max) }

    /// A scalar's text as written (strings without quotes, escapes kept), cut at `limit`
    /// characters for drawing.
    func value(_ node: Node, limit: Int = 300) -> String {
        string(start: node.valueStart, length: node.valueLength, limit: limit)
    }

    /// The node's JSON as written in the file.
    func source(_ node: Node) -> String {
        let start = node.kind == .string ? node.valueStart - 1 : node.valueStart
        let length = node.kind == .string ? node.valueLength + 2 : node.valueLength
        return string(start: start, length: length, limit: .max)
    }

    /// A string's value with its escapes decoded (for Copy Value).
    func decodedString(_ node: Node) -> String {
        let raw = "\"" + value(node, limit: .max) + "\""
        return (try? JSONDecoder().decode(String.self, from: Data(raw.utf8))) ?? value(node, limit: .max)
    }

    private func string(start: UInt32, length: UInt32, limit: Int) -> String {
        let from = data.startIndex + Int(start)
        let count = limit == .max ? Int(length) : min(Int(length), limit * 4)
        let text = String(decoding: data[from..<(from + count)], as: UTF8.self)
        return text.count > limit ? String(text.prefix(limit)) : text
    }

    /// The children of a container, by index.
    func children(_ index: Int) -> [Int] {
        let node = nodes[index]
        guard node.isContainer else { return [] }
        var result: [Int] = []
        result.reserveCapacity(Int(node.count))
        var child = index + 1
        while child < Int(node.end) {
            result.append(child)
            child = Int(nodes[child].end)
        }
        return result
    }

    /// Nodes whose key or scalar value holds `query` (case-insensitive), off the main actor.
    func matches(_ query: String) -> Set<Int> {
        let needle = Array(query.lowercased().utf8)
        guard !needle.isEmpty else { return [] }
        var found = Set<Int>()
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let bytes = buffer.bindMemory(to: UInt8.self)
            func contains(_ start: UInt32, _ length: UInt32) -> Bool {
                let n = Int(length)
                guard n >= needle.count else { return false }
                let base = Int(start)
                var i = 0
                while i + needle.count <= n {
                    var j = 0
                    while j < needle.count {
                        var byte = bytes[base + i + j]
                        if byte >= 0x41, byte <= 0x5A { byte += 0x20 }
                        if byte != needle[j] { break }
                        j += 1
                    }
                    if j == needle.count { return true }
                    i += 1
                }
                return false
            }
            for (index, node) in nodes.enumerated() {
                if node.hasKey, contains(node.keyStart, node.keyLength) {
                    found.insert(index)
                } else if !node.isContainer, contains(node.valueStart, node.valueLength) {
                    found.insert(index)
                }
            }
        }
        return found
    }

    // MARK: - Parsing

    /// JSON, or JSONL when `lines` (a value per line, blank lines skipped).
    static func parse(_ data: Data, lines: Bool) throws -> JSONIndex {
        var nodes: [Node] = []
        var roots: [UInt32] = []
        var rootLines: [Int32] = []
        let bomLength = data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var parser = Parser(bytes: bytes, position: bomLength)
            parser.skipSpace()
            while parser.position < bytes.count {
                let line = parser.line()
                roots.append(UInt32(nodes.count))
                rootLines.append(Int32(line))
                try parser.value(into: &nodes, key: (0, 0), parent: .max)
                parser.skipSpace()
                if !lines, parser.position < bytes.count {
                    throw parser.failure("Unexpected text after the end of the JSON")
                }
            }
            if roots.isEmpty { throw Failure(message: "The file is empty", line: 1) }
        }
        return JSONIndex(data: data, nodes: nodes, roots: roots, rootLines: lines ? rootLines : [])
    }

    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        var position: Int

        mutating func skipSpace() {
            while position < bytes.count {
                switch bytes[position] {
                case 0x20, 0x09, 0x0A, 0x0D: position += 1
                default: return
                }
            }
        }

        /// Lines counted so far, up to `counted`: each call counts only what's new, so a JSONL
        /// file's root lines cost one pass in all.
        private var lines = 1
        private var counted = 0

        init(bytes: UnsafeBufferPointer<UInt8>, position: Int) {
            self.bytes = bytes
            self.position = position
        }

        mutating func line() -> Int {
            let to = min(position, bytes.count)
            if to < counted {
                lines = 1
                counted = 0
            }
            for i in counted..<to where bytes[i] == 0x0A { lines += 1 }
            counted = to
            return lines
        }

        mutating func failure(_ message: String) -> Failure { Failure(message: message, line: line()) }

        /// One value at `position`, with its subtree, iteratively (no recursion, so deep files
        /// can't overflow the stack).
        mutating func value(into nodes: inout [Node], key: (UInt32, UInt32), parent: UInt32) throws {
            // Open containers: their node index, kind, start byte, children so far, key.
            var stack: [(index: Int, kind: Kind, start: Int, count: UInt32, key: (UInt32, UInt32), parent: UInt32)] = []
            var nextKey = key
            var nextParent = parent
            while true {
                skipSpace()
                guard position < bytes.count else { throw failure("The JSON ends too early") }
                let byte = bytes[position]
                if byte == 0x7B || byte == 0x5B {
                    // Placeholder until the container closes.
                    nodes.append(Node(kind: .null, keyStart: 0, keyLength: 0, valueStart: 0, valueLength: 0, count: 0, end: 0, parent: 0))
                    stack.append((nodes.count - 1, byte == 0x7B ? .object : .array, position, 0, nextKey, nextParent))
                    position += 1
                    skipSpace()
                    let close: UInt8 = byte == 0x7B ? 0x7D : 0x5D
                    if position < bytes.count, bytes[position] == close {
                        position += 1
                        try closeTop(&stack, &nodes)
                    } else {
                        nextParent = UInt32(nodes.count - 1)
                        nextKey = byte == 0x7B ? try memberKey() : (0, 0)
                        continue
                    }
                } else {
                    try scalar(into: &nodes, key: nextKey, parent: nextParent)
                }
                // After a value: a comma, or the open container's closing bracket.
                while let top = stack.last {
                    skipSpace()
                    guard position < bytes.count else { throw failure("The JSON ends too early") }
                    stack[stack.count - 1].count += 1
                    let byte = bytes[position]
                    if byte == 0x2C {
                        position += 1
                        nextParent = UInt32(top.index)
                        nextKey = top.kind == .object ? try memberKey() : (0, 0)
                        break
                    }
                    let close: UInt8 = top.kind == .object ? 0x7D : 0x5D
                    guard byte == close else {
                        throw failure(top.kind == .object ? "Expected , or } in an object" : "Expected , or ] in an array")
                    }
                    position += 1
                    try closeTop(&stack, &nodes)
                }
                if stack.isEmpty { return }
            }
        }

        private mutating func closeTop(
            _ stack: inout [(index: Int, kind: Kind, start: Int, count: UInt32, key: (UInt32, UInt32), parent: UInt32)],
            _ nodes: inout [Node]
        ) throws {
            let top = stack.removeLast()
            nodes[top.index] = Node(
                kind: top.kind, keyStart: top.key.0, keyLength: top.key.1, valueStart: UInt32(top.start),
                valueLength: UInt32(position - top.start), count: top.count, end: UInt32(nodes.count), parent: top.parent)
        }

        /// `"key":`, leaving `position` at the value.
        private mutating func memberKey() throws -> (UInt32, UInt32) {
            skipSpace()
            guard position < bytes.count, bytes[position] == 0x22 else { throw failure("Expected a key in quotes") }
            let (start, length) = try string()
            skipSpace()
            guard position < bytes.count, bytes[position] == 0x3A else { throw failure("Expected : after a key") }
            position += 1
            // A key of "" still counts as a key: start is never 0 inside an object.
            return (UInt32(start), UInt32(length))
        }

        private mutating func scalar(into nodes: inout [Node], key: (UInt32, UInt32), parent: UInt32) throws {
            let byte = bytes[position]
            let kind: Kind
            var start = position
            var length = 0
            switch byte {
            case 0x22:
                kind = .string
                (start, length) = try string()
            case 0x2D, 0x30...0x39:
                kind = .number
                while position < bytes.count {
                    let b = bytes[position]
                    guard (0x30...0x39).contains(b) || b == 0x2D || b == 0x2B || b == 0x2E || b == 0x65 || b == 0x45 else { break }
                    position += 1
                }
                length = position - start
            case 0x74: try literal("true"); kind = .bool; length = 4
            case 0x66: try literal("false"); kind = .bool; length = 5
            case 0x6E: try literal("null"); kind = .null; length = 4
            default:
                throw failure("Unexpected '\(Character(Unicode.Scalar(byte)))'")
            }
            nodes.append(Node(
                kind: kind, keyStart: key.0, keyLength: key.1, valueStart: UInt32(start), valueLength: UInt32(length),
                count: 0, end: UInt32(nodes.count + 1), parent: parent))
        }

        private mutating func literal(_ word: String) throws {
            let letters = Array(word.utf8)
            let count = letters.count
            guard position + count <= bytes.count else { throw failure("Unexpected end of the JSON") }
            for i in 0..<count where bytes[position + i] != letters[i] {
                throw failure("Unexpected '\(Character(Unicode.Scalar(bytes[position])))'")
            }
            position += count
        }

        /// A string at `position` (on its opening quote): its contents' start and length.
        private mutating func string() throws -> (Int, Int) {
            position += 1
            let start = position
            while position < bytes.count {
                switch bytes[position] {
                case 0x22:
                    let length = position - start
                    position += 1
                    return (start, length)
                case 0x5C: position += 2
                case 0x0A: throw failure("A string runs past the end of its line")
                default: position += 1
                }
            }
            throw failure("A string isn't closed")
        }
    }
}
