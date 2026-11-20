import Testing
@testable import elisctlKit

/// Runs a suite as outside any Elis pane, so its `active` defaults hold when `swift test` runs inside one.
struct OutsidePane: SuiteTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        try await CallerEnvironment.$values.withValue([:]) { try await function() }
    }
}

extension Trait where Self == OutsidePane {
    static var outsidePane: Self { Self() }
}
