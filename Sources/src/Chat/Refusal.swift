import Foundation
import Observation

/// A Claude turn the model's safeguards refused, with no fallback run (`model_refusal_no_fallback`).
/// They flag routine work too: the turn's notice offers it again on an earlier model of the same
/// family, or the message again with a line of context first.
package struct Refusal: Equatable, Sendable {
    /// The CLI's category: "cyber", "bio", "frontier_llm", "reasoning_extraction"; nil when unsaid.
    package let category: String?
    /// The model that refused, by its full id.
    package let model: String?

    package init(category: String?, model: String?) {
        self.category = category
        self.model = model
    }

    /// Where to go on, from the CLI's own model list, as its refusal table goes: a cyber flag to
    /// the newest model of the family's previous major version, anything else to the version
    /// just below. Nil when the list has none below.
    package func fallback(in models: [ModelOption]) -> ModelOption? {
        guard let model, let refused = Self.version(model) else { return nil }
        let earlier = models.compactMap { option -> (ModelOption, [Int])? in
            guard let version = Self.version(option.id), version.family == refused.family,
                  version.numbers.lexicographicallyPrecedes(refused.numbers) else { return nil }
            return (option, version.numbers)
        }
        let below = category == "cyber"
            ? earlier.filter { $0.1.first.map { $0 < refused.numbers.first ?? 0 } ?? false }
            : earlier
        return below.max { $0.1.lexicographicallyPrecedes($1.1) }?.0
    }

    /// A full id's family and version: "vendor-family-4-8" is ("vendor-family", [4, 8]); a
    /// dated suffix and a "[1m]" aren't version. Nil for an alias ("default", a bare family).
    package static func version(_ id: String) -> (family: String, numbers: [Int])? {
        let parts = (id.split(separator: "[").first.map(String.init) ?? id).split(separator: "-").map(String.init)
        guard let first = parts.firstIndex(where: { Int($0) != nil }), first >= 1 else { return nil }
        let numbers = parts[first...].prefix { $0.count < 8 }.compactMap(Int.init)
        guard !numbers.isEmpty else { return nil }
        return (parts[..<first].joined(separator: "-"), numbers)
    }

    /// A model's name as the CLI lists it, else from its id: "vendor-family-4-8" → "Family 4.8".
    package static func name(_ id: String, in models: [ModelOption] = []) -> String {
        if let listed = models.first(where: { $0.id == id }) { return listed.name }
        guard let version = version(id) else { return id }
        let family = version.family.split(separator: "-").last.map(String.init) ?? version.family
        return family.prefix(1).uppercased() + family.dropFirst() + " " + version.numbers.map(String.init).joined(separator: ".")
    }

    /// Put before the refused message by "Add context": what's true of the work, said plainly.
    package static let context = "Context: this is my own project, on my own machine and accounts, and I'm authorized to work on all of it. It's routine engineering (building, debugging, reviewing and operating my own systems), not aimed at anyone else's."
}

/// "Switch models when flagged" (Account, ⌘,): Claude chats start with the CLI's
/// `switchModelsOnFlag` on, so a refused turn goes again on its fallback model by itself. On by
/// default; a chat's CLI takes a change when it next starts. Passed per launch (`--settings`),
/// never written to the user's own settings.
@MainActor @Observable
package final class RefusalFallback {
    package static let shared = RefusalFallback()
    nonisolated private static let key = "switchModelsOnFlag"

    package var on = RefusalFallback.saved {
        didSet { UserDefaults.standard.set(on, forKey: Self.key) }
    }

    /// As saved, from any thread: a chat's CLI reads it as it starts.
    nonisolated package static var saved: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}
