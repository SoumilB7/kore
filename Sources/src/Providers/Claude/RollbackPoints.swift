import Foundation

/// Claude sessions cut back and not yet continued: the session's id and the message it's cut back
/// to. Kept across launches, because the session's file doesn't show the cut until the next
/// message is written.
package enum RollbackPoints {
    private static let key = "rollbackPoints"

    package static func at(_ session: String) -> String? { all[session] }

    package static func set(_ message: String, for session: String) {
        var points = all
        points[session] = message
        UserDefaults.standard.set(points, forKey: key)
    }

    package static func forget(_ session: String) {
        var points = all
        points[session] = nil
        UserDefaults.standard.set(points, forKey: key)
    }

    private static var all: [String: String] { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
}
