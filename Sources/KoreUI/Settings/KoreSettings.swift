import AppKit
import Foundation

/// Settings with no home of their own yet: what a new chat starts with, and the alerts while
/// Kore is in the background. All in UserDefaults; nothing set keeps Kore's behaviour.
enum KoreSettings {
    static let autoCompactKey = "kore.defaultAutoCompact"
    static func modelKey(_ provider: String) -> String { "kore.defaultModel.\(provider)" }
    static func effortKey(_ provider: String) -> String { "kore.defaultEffort.\(provider)" }
    static func modeKey(_ provider: String) -> String { "kore.defaultMode.\(provider)" }
    static func knownModelsKey(_ provider: String) -> String { "kore.knownModels.\(provider)" }

    /// The models a CLI listed last time one of its chats started (id, name, efforts), for the
    /// New Chats dropdowns; Claude's aliases until then.
    static func knownModels(_ provider: String) -> [(id: String, name: String, efforts: [String])] {
        let saved = (UserDefaults.standard.array(forKey: knownModelsKey(provider)) as? [[String: Any]] ?? []).compactMap { item -> (String, String, [String])? in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            return (id, name, item["efforts"] as? [String] ?? [])
        }
        if !saved.isEmpty { return saved }
        return provider == "claude" ? [("opus", "Opus", []), ("sonnet", "Sonnet", []), ("haiku", "Haiku", [])] : []
    }

    static func remember(models: [ModelOption], provider: String) {
        guard !models.isEmpty else { return }
        let items: [[String: Any]] = models.map { ["id": $0.id, "name": $0.name, "efforts": $0.efforts] }
        UserDefaults.standard.set(items, forKey: knownModelsKey(provider))
    }

    /// A new chat's auto-compact point: nil (never set) keeps the chat's own Off; 0 is Off.
    static func autoCompact(_ defaults: UserDefaults?) -> Int?? {
        guard let value = defaults?.object(forKey: autoCompactKey) as? Int else { return nil }
        return value == 0 ? .some(nil) : (ContextStore.snapPoints.contains(value) ? .some(value) : nil)
    }

    static func text(_ key: String, _ defaults: UserDefaults?) -> String? {
        defaults?.string(forKey: key).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: Restore defaults

    /// Every Kore setting back to its default: all "kore." keys but the models a CLI listed (data,
    /// not settings), the theme to Kore's, text size to 100%.
    @MainActor static func restoreDefaults() {
        let defaults = UserDefaults.standard
        let kept = ["kore.knownModels."]
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("kore.") && !kept.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
        Zoom.shared.reset()
        let appearance = Appearance.shared
        appearance.preview(Appearance.kore)
        appearance.save()
        appearance.refresh()
    }

    // MARK: Background alerts

    enum Alert: String, CaseIterable {
        case finished, approval
        var soundKey: String { "kore.alert.\(rawValue).sound" }
        var bounceKey: String { "kore.alert.\(rawValue).bounce" }
    }

    static let sounds = ["Glass", "Ping", "Pop", "Purr", "Hero", "Submarine", "Funk", "Tink", "Blow", "Bottle"]
}

/// A chat finished, or asks for an approval, while Kore isn't the front app: its sound, and a
/// Dock bounce, as set in Settings ▸ Notifications.
// shortcut: sound and Dock only; macOS banners need the bundled Kore.app (UNUserNotificationCenter).
@MainActor
enum ChatAlerts {
    static func note(_ event: ChatEvent) {
        let alert: KoreSettings.Alert
        switch event {
        case .turnFinished: alert = .finished
        case .approvalRequested: alert = .approval
        default: return
        }
        guard !NSApp.isActive else { return }
        let defaults = UserDefaults.standard
        if let name = defaults.string(forKey: alert.soundKey), !name.isEmpty { NSSound(named: name)?.play() }
        if defaults.bool(forKey: alert.bounceKey) { NSApp.requestUserAttention(alert == .approval ? .criticalRequest : .informationalRequest) }
    }
}
