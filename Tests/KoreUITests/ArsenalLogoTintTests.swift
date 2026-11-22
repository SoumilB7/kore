import Foundation
import SwiftUI
import Testing

@testable import KoreUI
@testable import src

/// A chat's CLI logo, working spinner and ">_" take Arsenal's one colour while it has Arsenal at
/// any tier, Claude's and Codex's alike; off, they keep their own colours.
@MainActor
@Suite("Arsenal: the logo, spinner and >_ tint")
struct ArsenalLogoTintTests {
    @Test(arguments: [Provider.claude, .codex])
    func offKeepsTheLogo(_ provider: Provider) {
        let chat = Chat(provider: provider, folder: URL(fileURLWithPath: "/tmp"))
        #expect(chat.arsenal == nil)
        #expect(ProviderLogo.tint(chat.arsenal) == nil)
    }

    @Test(arguments: [Provider.claude, .codex])
    func everyTierIsOneColour(_ provider: Provider) {
        let chat = Chat(provider: provider, folder: URL(fileURLWithPath: "/tmp"))
        for tier in ArsenalTier.allCases {
            chat.arsenal = tier
            #expect(ProviderLogo.tint(chat.arsenal) == Theme.Arsenal.mark, "\(provider.id) at \(tier.rawValue)")
        }
        chat.arsenal = nil
        #expect(ProviderLogo.tint(chat.arsenal) == nil)
    }

    @Test func markIsTheButtonsBlue() {
        #expect(Theme.Arsenal.mark == Theme.Arsenal.color(.drive))
    }

    @Test(arguments: [Provider.claude, .codex])
    func spinnerAndPromptOff(_ provider: Provider) {
        let own = provider == .claude ? WorkingSpinner.claude : Color.white
        #expect(WorkingSpinner.tint(provider, arsenal: nil) == own)
        #expect(BackgroundPrompt(provider: provider).tint == own)
    }

    @Test(arguments: [Provider.claude, .codex])
    func spinnerAndPromptEveryTier(_ provider: Provider) {
        for tier in ArsenalTier.allCases {
            #expect(WorkingSpinner.tint(provider, arsenal: tier) == Theme.Arsenal.mark, "\(provider.id) at \(tier.rawValue)")
            #expect(BackgroundPrompt(provider: provider, arsenal: tier).tint == Theme.Arsenal.mark, "\(provider.id) at \(tier.rawValue)")
        }
    }
}
