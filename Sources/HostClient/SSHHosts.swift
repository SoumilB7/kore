import Foundation

/// The hosts named in `~/.ssh/config`, read only (never written): each `Host` line's names, without
/// patterns (`*`, `?`, `!`), Git hosts, and tunnels named `…-login` or `…-browser`, which aren't
/// boxes. Read again only when the file changed.
package enum SSHHosts {
    package static var config: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    nonisolated(unsafe) private static var read: (stamp: Date?, aliases: [String])?
    private static let lock = NSLock()

    package static func aliases(in file: URL = config) -> [String] {
        let stamp = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return lock.withLock {
            if file == config, let read, read.stamp == stamp { return read.aliases }
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let aliases = parse(text)
            if file == config { read = (stamp, aliases) }
            return aliases
        }
    }

    static func skipped(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["github.com", "gitlab.com", "bitbucket.org"].contains(lower) || lower.hasSuffix("-login") || lower.hasSuffix("-browser")
    }

    package static func parse(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            // "Host a b", "Host=a", "host a # note"
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
            guard let key = words.first, key.lowercased() == "host" else { continue }
            for name in words.dropFirst() {
                if name.hasPrefix("#") { break }
                let name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard !name.isEmpty, !name.contains(where: { "*?!".contains($0) }), !out.contains(name), !skipped(name) else { continue }
                out.append(name)
            }
        }
        return out
    }
}
