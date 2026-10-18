import Foundation

/// A value a storyline host (phase 12's `kore-storylines`) sets once at launch, read by KoreCore
/// from any thread. It keeps its default in Kore itself, so the app runs as it always has.
package final class HostSetting<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    package init(_ value: Value) {
        stored = value
    }

    package var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
