import Foundation

/// A reusable piece of a storyline. Steps never sleep: they act, then wait for a condition
/// (`StoryContext.wait`), which fails the step when its timeout passes.
package protocol Step {
    /// How the report names it: "Open folder", "Wait for the replay".
    var label: String { get }
    /// nil: the run's default (`StoryContext.timeout`).
    var timeout: Duration? { get }
    @MainActor func run(_ story: StoryContext) async throws
}

extension Step {
    package var timeout: Duration? { nil }
}

/// Why a step failed, as the report shows it.
package enum StoryFailure: Error, CustomStringConvertible {
    /// A wait's condition didn't hold in time.
    case timedOut(String)
    /// A check found something else.
    case expectation(String)
    /// The locator's element isn't registered (package B; the id becomes `StoryID` once it lands).
    case elementNotFound(String, nearby: [String])
    /// The model doesn't have what the step names.
    case modelMissing(String)
    /// The step needs `--real-input` (hover).
    case needsRealInput(String)
    case other(String)

    package var description: String {
        switch self {
        case .timedOut(let what): "timed out waiting for \(what)"
        case .expectation(let what): "expected \(what)"
        case .elementNotFound(let id, let nearby):
            "element not found: \(id)" + (nearby.isEmpty ? "" : " (registered nearby: \(nearby.joined(separator: ", ")))")
        case .modelMissing(let what): "not in the model: \(what)"
        case .needsRealInput(let what): "\(what) needs --real-input"
        case .other(let what): what
        }
    }
}
