import Foundation

/// A lock around a value, for state shared across queues.
package final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    package init(_ value: Value) { self.value = value }
    package func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
