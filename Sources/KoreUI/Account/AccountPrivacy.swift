import Foundation
import Observation

/// The Account card's privacy mode (account-privacy.html): emails shown as their first two
/// characters, four dots and the domain ("on••••@gmail.com"). Kept across opens and launches.
@MainActor @Observable
final class AccountPrivacy {
    static let shared = AccountPrivacy()
    private static let key = "accountPrivacy"

    var on = UserDefaults.standard.bool(forKey: key) {
        didSet { UserDefaults.standard.set(on, forKey: Self.key) }
    }

    /// An email as the card shows it: masked while privacy is on.
    func shown(_ email: String) -> String { on ? Self.mask(email) : email }

    /// The name's first two letters and the domain's last two before its ending:
    /// "ku••••@••il.com". Always the same dots, so no length is given away.
    nonisolated static func mask(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return String(email.prefix(2)) + "••••" }
        let domain = email[email.index(after: at)...]
        guard let dot = domain.lastIndex(of: "."), dot > domain.startIndex else {
            return String(email[..<at].prefix(2)) + "••••@••" + String(domain.suffix(2))
        }
        return String(email[..<at].prefix(2)) + "••••@••" + String(domain[..<dot].suffix(2)) + domain[dot...]
    }

    /// A plan's pill: the plan without its product's name ("Claude Max" → "Max", "ChatGPT Pro
    /// Lite" → "Pro Lite"); "API" for a login billed per token.
    nonisolated static func pill(plan: String?, perToken: Bool) -> String? {
        if perToken { return "API" }
        guard var plan = plan?.trimmingCharacters(in: .whitespaces), !plan.isEmpty else { return nil }
        for product in ["Claude ", "ChatGPT "] where plan.hasPrefix(product) { plan.removeFirst(product.count) }
        return plan.isEmpty ? nil : plan
    }
}
