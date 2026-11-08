import Foundation
import KoreCore

/// hosts.log's fields: a box's events as `key=value`, never free text; a link that was up is one
/// `link` line as it ends, a carry one `carry` line.
///
///   …Z info link id=3fa2c1 host=mybox route=net device=419e… dur_ms=754012 end=switch
///   …Z info carry id=8d0e44aa host=mybox mode=copy files=12 bytes=40960 dur_ms=2310 result=done
extension HostLog {
    /// One event with its fields, under the box it's about.
    package static func event(_ alias: String, _ what: String, level: KoreLog.Level = .info, _ fields: KeyValuePairs<String, String?>) {
        event(alias, what, level: level, fields.map { (key: $0.key, value: $0.value) })
    }

    package static func event(_ alias: String, _ what: String, level: KoreLog.Level = .info, _ fields: [(key: String, value: String?)]) {
        KoreLog.named("hosts").write(level, what, [(key: "host", value: alias)] + fields)
    }

    /// A link's end: one wide `link` line when it was up (`up`: since when), else `dropped`.
    package static func linkEnded(_ alias: String, id: String?, route: HostRoute?, up: Date?, reason: String?) {
        let end = ending(reason)
        guard let up, let id else { return KoreLog.named("hosts").write(.warn, "dropped", ["host": alias, "end": end]) }
        let routeName: String? = switch route {
        case .net: "net"
        case .ssh: "ssh"
        case nil: nil
        }
        let device = NodeDirectory.isNodeKey(alias) ? alias.lowercased() : NodeDirectory.shared.entry(forKey: alias)?.id.raw
        KoreLog.named("hosts").write(
            end == "switch" ? .info : .warn, "link",
            ["id": id, "host": alias, "route": routeName, "device": device, "dur_ms": String(Int(Date().timeIntervalSince(up) * 1000)), "end": end])
    }

    /// Why a link ended, in a word.
    package static func ending(_ reason: String?) -> String {
        guard let reason = reason?.lowercased() else { return "closed" }
        if reason.contains("korenet") { return "switch" }
        if reason.contains("no answer") { return "no-answer" }
        if reason.contains("couldn't start") { return "start-failed" }
        if reason.contains("newer link") { return "replaced" }
        if reason.contains("waited too long") { return "slow-hello" }
        if let said = reason.components(separatedBy: " said ").dropFirst().last { return word(said) ?? "refused" }
        return word(reason) ?? "closed"
    }

    /// `text` as one readable token, never dropped: each path cut to its last part, anything
    /// token-shaped redacted, apostrophes gone, and every run of anything but letters, digits and
    /// `_.:` one `-` ("the box's identity key changed" → `the-boxs-identity-key-changed`); at most
    /// 96 long. Nil only when nothing's left.
    package static func word(_ text: String) -> String? {
        let cut = text.split(whereSeparator: \.isWhitespace).map { piece in
            piece.contains("/") ? piece.split(separator: "/").last.map(String.init) ?? "" : String(piece)
        }
        var token = ""
        var gap = false
        for character in KoreLog.redacted(cut.joined(separator: " ")) where character != "'" && character != "\u{2019}" {
            if character.isASCII, character.isLetter || character.isNumber || "_.:".contains(character) {
                if gap, !token.isEmpty { token.append("-") }
                gap = false
                token.append(character)
            } else {
                gap = true
            }
        }
        let short = String(token.prefix(96))
        let trimmed = short.hasSuffix("-") ? String(short.dropLast()) : short
        return trimmed.isEmpty ? nil : trimmed
    }
}
