import AgentTools
import Foundation

/// `kore logs [--since 10m] [--chat X] [--turn T] [--level warn] [-f] [--json] [log…]`: Kore's own
/// logs from their files, merged by time; no Kore needed. The last hour unless `--since` says.
enum Logs {
    static let usage = "kore logs [--since 10m] [--chat X] [--turn T] [--level warn] [-f] [--json] [log…]"

    struct Options {
        var filter = LogQuery.Filter()
        var follow = false
        var json = false
        var problem: String?

        init(_ args: [String], now: Date = Date()) {
            var rest = args[...]
            var since: Date? = now.addingTimeInterval(-3600)
            while let arg = rest.popFirst() {
                switch arg {
                case "--json": json = true
                case "-f", "--follow": follow = true
                case "--since":
                    guard let text = rest.popFirst(), let date = LogQuery.since(text, now: now) else { problem = "--since takes 10m, 2h, 3d or a time"; return }
                    since = date
                case "--all": since = nil
                case "--chat":
                    guard let chat = rest.popFirst() else { problem = "--chat takes a chat id"; return }
                    filter.chat = chat
                case "--turn":
                    guard let turn = rest.popFirst() else { problem = "--turn takes a turn id"; return }
                    filter.turn = turn
                case "--level":
                    guard let level = rest.popFirst()?.lowercased(), LogQuery.levels.contains(level) else {
                        problem = "--level takes debug, info, warn or error"
                        return
                    }
                    filter.level = level
                default:
                    if arg.hasPrefix("-") { problem = "unknown option \(arg)"; return }
                    filter.logs.insert(arg.hasSuffix(".log") ? String(arg.dropLast(4)) : arg)
                }
            }
            filter.since = since
        }
    }

    static func run(_ args: [String]) -> Int32 {
        let options = Options(args)
        if let problem = options.problem { return Reads.fail(problem + "\nusage: " + usage, code: 2) }
        let folder = LogQuery.folder()
        guard FileManager.default.fileExists(atPath: folder.path) else { return Reads.fail("no logs at \(folder.path)", code: 1) }
        for line in LogQuery.read(folder, options.filter) { show(line, options) }
        guard options.follow else { return 0 }
        follow(folder, options)
    }

    static func show(_ line: LogQuery.Line, _ options: Options) {
        print(options.json ? LogQuery.json(line) : Reads.safe(LogQuery.shown(line)))
        fflush(stdout)
    }

    /// Each log's new lines as they're written, until interrupted. A log that moves aside starts
    /// over from its new file's top.
    static func follow(_ folder: URL, _ options: Options) -> Never {
        var offsets: [String: (inode: UInt64, offset: UInt64)] = [:]
        func live() -> [URL] { LogQuery.files(in: folder).filter { $0.pathExtension == "log" } }
        for file in live() {
            offsets[file.path] = (inode(file), size(file))
        }
        var filter = options.filter
        filter.since = nil
        while true {
            Thread.sleep(forTimeInterval: 0.5)
            for file in live() {
                let node = inode(file)
                let start = offsets[file.path].flatMap { $0.inode == node ? $0.offset : nil } ?? 0
                let end = size(file)
                guard end > start, let handle = try? FileHandle(forReadingFrom: file) else {
                    offsets[file.path] = (node, min(start, end))
                    continue
                }
                try? handle.seek(toOffset: start)
                let data = (try? handle.read(upToCount: Int(end - start))) ?? Data()
                try? handle.close()
                // Only whole lines: a line half written is read next time.
                let whole = data.lastIndex(of: UInt8(ascii: "\n")).map { data.prefix(through: $0) } ?? Data()
                offsets[file.path] = (node, start + UInt64(whole.count))
                let log = LogQuery.name(of: file)
                for text in String(decoding: whole, as: UTF8.self).split(separator: "\n") {
                    if let line = LogQuery.parse(Substring(text), log: log), filter.keeps(line) { show(line, options) }
                }
            }
        }
    }

    private static func inode(_ file: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    private static func size(_ file: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
