import Foundation

/// A chat named on the command line: `.` (the caller's own), its id, a short id, or a part of its
/// title only one chat has (a title equal to it wins over ones that only hold it).
package enum AgentRefs {
    /// A chat's short id: the first 8 of its id, as every list shows it.
    package static func short(_ id: String) -> String { String(id.prefix(8)).lowercased() }

    package enum Found: Equatable, Sendable {
        case chat(String)
        case none
        case notInChat
        /// Several chats match: their ids.
        case ambiguous([String])
    }

    package static func resolve(_ ref: String, chats: [(id: String, title: String)], own: String?) -> Found {
        let ref = ref.trimmingCharacters(in: .whitespaces)
        if ref == "." { return own.map(Found.chat) ?? .notInChat }
        let lower = ref.lowercased()
        guard !lower.isEmpty else { return .none }
        if let exact = chats.first(where: { $0.id.lowercased() == lower }) { return .chat(exact.id) }
        let byId = lower.count >= 4 && lower.allSatisfy({ $0.isHexDigit || $0 == "-" }) ? chats.filter { $0.id.lowercased().hasPrefix(lower) } : []
        if byId.count == 1 { return .chat(byId[0].id) }
        let equal = chats.filter { $0.title.lowercased() == lower }
        if equal.count == 1 { return .chat(equal[0].id) }
        let holding = equal.count > 1 ? equal : chats.filter { $0.title.lowercased().contains(lower) }
        switch holding.count {
        case 0: return byId.isEmpty ? .none : .ambiguous(byId.map(\.id))
        case 1: return .chat(holding[0].id)
        default: return .ambiguous(holding.map(\.id))
        }
    }

    /// A chat named by its id alone (`chat.close`, the owner, 2026-11-17).
    package enum IDFound: Equatable, Sendable {
        case chat(String)
        case none
        /// `.`: a chat never closes itself.
        case itself
        /// No id is `ref`, but these chats' titles hold it: a title never names one here.
        case byTitle([String])
        /// Several chats' ids start the same as their short ids: give the full id.
        case ambiguous([String])
    }

    /// Its full id or its short id (`AgentReads.short`, the first 8), nothing else: duplicate
    /// titles exist, so a title never names the chat, not even one only one chat has.
    package static func resolveID(_ ref: String, chats: [(id: String, title: String)]) -> IDFound {
        let lower = ref.trimmingCharacters(in: .whitespaces).lowercased()
        if lower == "." { return .itself }
        guard !lower.isEmpty else { return .none }
        if let exact = chats.first(where: { $0.id.lowercased() == lower }) { return .chat(exact.id) }
        let short = chats.filter { $0.id.prefix(8).lowercased() == lower }
        if short.count == 1 { return .chat(short[0].id) }
        if short.count > 1 { return .ambiguous(short.map(\.id)) }
        let titled = chats.filter { $0.title.lowercased().contains(lower) }
        return titled.isEmpty ? .none : .byTitle(titled.map(\.id))
    }
}
