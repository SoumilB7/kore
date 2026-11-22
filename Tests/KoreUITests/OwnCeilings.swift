import Testing
import src

/// Each test with mode ceilings of its own (`ModeCeilings.kept`): none it leaves reaches another
/// test, or a later run.
struct OwnCeilings: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { return try await function() }
        try await ModeCeilings.kept { try await function() }
    }
}

extension Trait where Self == OwnCeilings {
    static var ownCeilings: Self { Self() }
}
