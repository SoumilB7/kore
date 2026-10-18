import Foundation

/// A CSV or TSV file as rows of cells, kept as byte ranges into the file's data, so a 50k-row
/// file costs its bytes plus eight bytes a cell. A cell's text is decoded only when it's drawn,
/// copied or sorted. RFC 4180 quoting: `"a, b"`, `""` for a quote, line breaks inside quotes.
final class DelimitedTable: Sendable {
    enum Delimiter: UInt8, Sendable {
        case comma = 0x2C
        case tab = 0x09
        case semicolon = 0x3B
        case pipe = 0x7C

        var name: String {
            switch self {
            case .comma: "Comma"
            case .tab: "Tab"
            case .semicolon: "Semicolon"
            case .pipe: "Pipe"
            }
        }
    }

    /// One cell: where it starts, how long it is, and whether it was quoted (and so may hold
    /// doubled quotes).
    struct Cell: Sendable {
        let start: UInt32
        /// The sign bit marks a quoted cell.
        let packed: Int32

        var length: Int { Int(packed & Int32.max) }
        var quoted: Bool { packed < 0 }
    }

    let data: Data
    let delimiter: Delimiter
    /// Row r's cells are `cells[rowStarts[r]..<rowStarts[r + 1]]`; row 0 is the header.
    private let rowStarts: [Int32]
    private let cells: [Cell]
    let columns: Int
    /// The file had more rows than `limit`; the rest weren't read.
    let capped: Bool
    /// Columns whose values are mostly numbers: right-aligned, and sorted as numbers.
    let numeric: [Bool]

    /// Rows after the header.
    var rows: Int { rowStarts.count - 2 }

    private init(data: Data, delimiter: Delimiter, rowStarts: [Int32], cells: [Cell], columns: Int, capped: Bool) {
        self.data = data
        self.delimiter = delimiter
        self.rowStarts = rowStarts
        self.cells = cells
        self.columns = columns
        self.capped = capped
        var numeric: [Bool] = []
        let sample = min(rowStarts.count - 2, 200)
        for column in 0..<columns {
            var numbers = 0
            var filled = 0
            for row in 1..<(sample + 1) {
                let text = Self.text(data: data, cells: cells, rowStarts: rowStarts, row: row, column: column)
                guard !text.isEmpty else { continue }
                filled += 1
                if Self.number(text) != nil { numbers += 1 }
            }
            numeric.append(filled > 0 && numbers * 10 >= filled * 9)
        }
        self.numeric = numeric
    }

    /// The text of a cell (row 0 is the header); "" past a short row's end.
    func text(row: Int, column: Int) -> String {
        Self.text(data: data, cells: cells, rowStarts: rowStarts, row: row, column: column)
    }

    /// How many cells the row has (rows can be ragged).
    func count(row: Int) -> Int { Int(rowStarts[row + 1] - rowStarts[row]) }

    private static func text(data: Data, cells: [Cell], rowStarts: [Int32], row: Int, column: Int) -> String {
        let first = Int(rowStarts[row])
        guard column < Int(rowStarts[row + 1]) - first else { return "" }
        let cell = cells[first + column]
        let start = data.startIndex + Int(cell.start)
        let raw = String(decoding: data[start..<(start + cell.length)], as: UTF8.self)
        return cell.quoted ? raw.replacingOccurrences(of: "\"\"", with: "\"") : raw
    }

    static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.utf8.first, first == 0x2D || first == 0x2B || first == 0x2E || (0x30...0x39).contains(first)
        else { return nil }
        return Double(trimmed.replacingOccurrences(of: ",", with: ""))
    }

    // MARK: - Parsing

    enum Failure: Error {
        case notText
    }

    static func parse(_ data: Data, isTSV: Bool, limit: Int) throws -> DelimitedTable {
        var body = data
        if body.starts(with: [0xEF, 0xBB, 0xBF]) { body = body.dropFirst(3) }
        if body.prefix(8192).contains(0) { throw Failure.notText }
        let delimiter = isTSV ? .tab : sniff(body)
        let separator = delimiter.rawValue
        var rowStarts: [Int32] = [0]
        var cells: [Cell] = []
        var columns = 0
        var capped = false
        body.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let bytes = buffer.bindMemory(to: UInt8.self)
            let n = bytes.count
            let base = body.startIndex - data.startIndex
            var i = 0
            var rowCells = 0
            func endRow() {
                rowStarts.append(Int32(cells.count))
                columns = max(columns, rowCells)
                rowCells = 0
            }
            while i < n {
                // One cell.
                var start = i
                var length = 0
                var quoted = false
                if bytes[i] == 0x22 {
                    quoted = true
                    i += 1
                    start = i
                    while i < n {
                        if bytes[i] == 0x22 {
                            if i + 1 < n, bytes[i + 1] == 0x22 {
                                i += 2
                                continue
                            }
                            break
                        }
                        i += 1
                    }
                    length = i - start
                    // The closing quote, then anything up to the separator (lenient).
                    while i < n, bytes[i] != separator, bytes[i] != 0x0A, bytes[i] != 0x0D { i += 1 }
                } else {
                    while i < n, bytes[i] != separator, bytes[i] != 0x0A, bytes[i] != 0x0D { i += 1 }
                    length = i - start
                }
                cells.append(Cell(start: UInt32(base + start), packed: Int32(length) | (quoted ? Int32.min : 0)))
                rowCells += 1
                if i < n, bytes[i] == separator {
                    i += 1
                    // A trailing separator leaves one more, empty cell.
                    if i == n || bytes[i] == 0x0A || bytes[i] == 0x0D {
                        cells.append(Cell(start: UInt32(base + i), packed: 0))
                        rowCells += 1
                    } else {
                        continue
                    }
                }
                // End of line: \n, \r\n or \r.
                if i < n, bytes[i] == 0x0D { i += 1 }
                if i < n, bytes[i] == 0x0A { i += 1 }
                endRow()
                if rowStarts.count > limit + 1 {
                    capped = i < n
                    return
                }
            }
            if rowCells > 0 { endRow() }
        }
        // Always a header row, even for an empty file.
        if rowStarts.count == 1 { rowStarts.append(0) }
        return DelimitedTable(
            data: data, delimiter: delimiter, rowStarts: rowStarts, cells: cells, columns: max(columns, 1), capped: capped)
    }

    /// A .csv file's separator: whichever of `,` `;` `\t` `|` appears most, outside quotes, in
    /// its first line (Rainbow CSV's guess); comma on a tie.
    private static func sniff(_ data: Data) -> Delimiter {
        var counts: [Delimiter: Int] = [:]
        var quoted = false
        for byte in data.prefix(4096) {
            if byte == 0x22 { quoted.toggle() }
            if quoted { continue }
            if byte == 0x0A { break }
            if let delimiter = Delimiter(rawValue: byte) { counts[delimiter, default: 0] += 1 }
        }
        let comma = counts[.comma] ?? 0
        guard let best = counts.max(by: { $0.value < $1.value }), best.value > comma else { return .comma }
        return best.key
    }

    // MARK: - Sorting

    /// The data rows (1-based) in a column's order: numbers as numbers in a numeric column,
    /// text by Finder's order otherwise; empty cells last either way. Stable.
    func order(column: Int, ascending: Bool) -> [Int32] {
        guard self.rows > 0 else { return [] }
        let rows = Array(Int32(1)...Int32(self.rows))
        if numeric[column] {
            let keys = rows.map { Self.number(text(row: Int($0), column: column)) }
            return rows.indices.sorted { a, b in
                switch (keys[a], keys[b]) {
                case (let x?, let y?): x == y ? a < b : (ascending ? x < y : x > y)
                case (nil, nil): a < b
                case (nil, _): false
                case (_, nil): true
                }
            }.map { rows[$0] }
        }
        let keys = rows.map { text(row: Int($0), column: column) }
        return rows.indices.sorted { a, b in
            let x = keys[a]
            let y = keys[b]
            if x.isEmpty != y.isEmpty { return !x.isEmpty }
            let result = x.localizedStandardCompare(y)
            if result == .orderedSame { return a < b }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }.map { rows[$0] }
    }
}
