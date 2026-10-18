import Combine

/// Stand-in for @State: its macro plugin ships only with full Xcode, and Kore builds with
/// the Command Line Tools. `@StateObject private var x = Local(value)` behaves the same.
final class Local<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

/// View-owned storage that never re-renders the view when it changes: scroll geometry and other
/// values a view keeps for itself between updates. `@StateObject private var x = Held(value)`.
final class Held<Value>: ObservableObject {
    var value: Value
    init(_ value: Value) { self.value = value }
}
