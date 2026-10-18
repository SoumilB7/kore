import Combine

/// Stand-in for @State: its macro plugin ships only with full Xcode, and Kore builds with
/// the Command Line Tools. `@StateObject private var x = Local(value)` behaves the same.
/// Like @State, setting an Equatable value to what it already is re-renders nothing.
final class Local<Value>: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private let same: (Value, Value) -> Bool
    var value: Value {
        willSet { if !same(value, newValue) { objectWillChange.send() } }
    }

    init(_ value: Value) {
        self.value = value
        same = { _, _ in false }
    }

    init(_ value: Value) where Value: Equatable {
        self.value = value
        same = (==)
    }
}

/// View-owned storage that never re-renders the view when it changes: scroll geometry and other
/// values a view keeps for itself between updates. `@StateObject private var x = Held(value)`.
final class Held<Value>: ObservableObject {
    var value: Value
    init(_ value: Value) { self.value = value }
}
