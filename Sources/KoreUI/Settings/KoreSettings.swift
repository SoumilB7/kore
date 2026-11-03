import AppKit
import Foundation

/// Settings with no home of their own yet: what a new chat starts with, the code font, and the
/// alerts while Kore is in the background. All in UserDefaults; nothing set keeps Kore's behaviour.
enum KoreSettings {
    static let autoCompactKey = "kore.defaultAutoCompact"
    /// The buttons under a message (each on unless turned off), and copying a finished selection.
    static let copyButtonKey = "kore.actions.copy"
    static let forkButtonKey = "kore.actions.fork"
    static let selectionCopyKey = "kore.selection.copy"
    /// The prompt box across the chat's whole width, not capped at 760.
    static let fullWidthComposerKey = "kore.composer.fullWidth"
    static let codeFontKey = "kore.codeFont"
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

    // MARK: Code font

    /// The family code is drawn in (transcript code, editor, selection); Menlo when unset or gone.
    /// The regular face's PostScript name ("MesloLGSNFM-Regular"): SwiftUI's `Font.custom` and Core
    /// Text match a PostScript or full name, not a family ("MesloLGS Nerd Font Mono"), and fall back
    /// to the system font without a word when given one.
    static var codeFont: String {
        guard let family = UserDefaults.standard.string(forKey: codeFontKey) else { return "Menlo" }
        return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12)?.fontName
            ?? NSFont(name: family, size: 12)?.fontName ?? "Menlo"
    }

    static func codeFont(size: CGFloat, bold: Bool = false) -> NSFont {
        guard let font = NSFont(name: codeFont, size: size) else {
            return .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
        }
        return bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
    }

    /// Starts a new Kore and quits this one; open tabs come back, as after any quit.
    @MainActor static func relaunch() {
        let bundle = Bundle.main.bundleURL
        let process = Process()
        if bundle.pathExtension == "app" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", bundle.path]
        } else {
            // `swift run` / .build/debug/Kore: the same binary again, after this one has gone.
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "sleep 1; exec \"$0\"", CommandLine.arguments[0]]
        }
        guard (try? process.run()) != nil else { return }
        NSApp.terminate(nil)
    }

    /// Installed fixed-pitch families, for the picker.
    @MainActor static func monospacedFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies.filter { NSFont(name: $0, size: 12)?.isFixedPitch == true }
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
