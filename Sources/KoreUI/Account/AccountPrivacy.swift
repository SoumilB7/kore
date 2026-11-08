import Foundation
import LinkProtocol
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
    nonisolated static func mask(_ email: String) -> String { AccountUsage.mask(email) }

    /// A plan's pill: the plan without its product's name ("Claude Max" → "Max", "ChatGPT Pro
    /// Lite" → "Pro Lite"); "API" for a login billed per token.
    nonisolated static func pill(plan: String?, perToken: Bool) -> String? { AccountUsage.pill(plan: plan, perToken: perToken) }
}
