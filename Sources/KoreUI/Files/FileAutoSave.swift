import Foundation
import Observation

/// One delayed save per editing burst. Clean files have no task or timer; the weak list
/// only lets a preference change cancel or schedule the documents already open.
@MainActor @Observable
package final class FileAutoSave {
    package static let shared = FileAutoSave()
    private static let key = "fileAutoSave"
    package var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults?.set(isEnabled, forKey: Self.key)
            for document in documents.allObjects { document.autoSaveChanged() }
            UILog.event("file-auto-save-setting", ["enabled": "\(isEnabled)"])
        }
    }
    @ObservationIgnored let delay: Duration
    @ObservationIgnored let pause: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let documents = NSHashTable<FileDocument>.weakObjects()

    init(defaults: UserDefaults? = .standard, delay: Duration = .milliseconds(750),
         pause: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.defaults = defaults
        self.delay = delay
        self.pause = pause
        isEnabled = defaults?.object(forKey: Self.key) as? Bool ?? true
    }

    func register(_ document: FileDocument) { documents.add(document) }
}
