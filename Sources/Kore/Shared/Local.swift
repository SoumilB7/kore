import Combine

/// Stand-in for @State: its macro plugin ships only with full Xcode, and Kore builds with
/// the Command Line Tools. `@StateObject private var x = Local(value)` behaves the same.
final class Local<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}
