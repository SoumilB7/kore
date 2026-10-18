import AppKit
import KoreUI

/// What one look for an element found.
@MainActor
package enum Resolution {
    /// Registered and in a window.
    case found(StoryElement)
    /// The model has it and the registry doesn't yet: a lazy row not built, or a view still
    /// appearing. A reveal was asked for where there is one; look again on the next pass.
    case revealing(StoryID)
    /// The model doesn't have it, so waiting won't help: what the store has instead.
    case missing(String)
    /// The model can't say yet (a file still loading, folds still being worked out).
    case waiting(String)
}

/// An element as a step names it, in the user's terms (phase 12, §3): "answer 2's Fork", "the
/// send button", "the tree row for Sources/Greet.swift". It resolves through the stores to a
/// StoryID and then through the registry, at whatever size, zoom and scroll the window has.
@MainActor
package struct Locator: CustomStringConvertible {
    package let description: String
    /// The element's name, from the stores; a miss says what the store has instead.
    private let key: @MainActor (AppProbe) -> Result<StoryID, LocatorMiss>
    /// Asks the list holding it to build it, when it's lazy (a transcript row above the window).
    private let reveal: (@MainActor (AppProbe) -> Void)?

    package init(
        _ description: String, key: @escaping @MainActor (AppProbe) -> Result<StoryID, LocatorMiss>,
        reveal: (@MainActor (AppProbe) -> Void)? = nil
    ) {
        self.description = description
        self.key = key
        self.reveal = reveal
    }

    /// One synchronous look, no waiting: steps wait through `StoryContext.element(_:)`.
    package func resolve(_ app: AppProbe) -> Resolution {
        switch key(app) {
        case .failure(let miss): return miss.pending ? .waiting(miss.what) : .missing(miss.what)
        case .success(let id):
            if let element = StoryElement(id) { return .found(element) }
            reveal?(app)
            return .revealing(id)
        }
    }

    /// An element by its name, for fixed controls and one-off checks.
    package static func id(_ id: StoryID) -> Locator { Locator(id.raw, key: { _ in .success(id) }) }

    /// A control inside this element (`.answer(turn: 1).action(.fork)`), found and revealed the
    /// same way.
    package func action(_ part: StoryID.Part) -> Locator {
        let key = key
        return Locator("\(description) › \(part.rawValue)", key: { app in key(app).map { $0.part(part) } }, reveal: reveal)
    }
}

/// Why a locator's key isn't in the model: for good, or not yet (`pending`).
package struct LocatorMiss: Error {
    package let what: String
    package let pending: Bool
    package init(_ what: String, pending: Bool = false) {
        self.what = what
        self.pending = pending
    }
}

extension StoryContext {
    /// Waits for the locator's element. A miss in the model fails at once; a timeout fails as
    /// not found, with the registered names nearest the one it wanted.
    package func element(_ locator: Locator, timeout: Duration? = nil) async throws -> StoryElement {
        var wanted: StoryID?
        var notYet: String?
        do {
            return try await wait(locator.description, timeout: timeout) { () throws -> StoryElement? in
                switch locator.resolve(self.app) {
                case .found(let element): return element
                case .revealing(let id):
                    wanted = id
                    return nil
                case .waiting(let what):
                    notYet = what
                    return nil
                case .missing(let what): throw StoryFailure.modelMissing(what)
                }
            }
        } catch StoryFailure.timedOut {
            if wanted == nil, let notYet { throw StoryFailure.modelMissing(notYet) }
            let id = wanted?.raw ?? locator.description
            throw StoryFailure.elementNotFound(id, nearby: StoryRegistry.nearest(to: id))
        }
    }
}
