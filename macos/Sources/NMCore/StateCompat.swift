import SwiftUI

@propertyWrapper
public struct NMStateCompat<Value>: DynamicProperty {
    private final class Box: ObservableObject {
        @Published var value: Value

        init(_ value: Value) { self.value = value }
    }

    @StateObject private var box: Box

    public init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: Box(wrappedValue))
    }

    public mutating func update() {
        _box.update()
    }

    public var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    public var projectedValue: Binding<Value> {
        Binding(get: { box.value }, set: { box.value = $0 })
    }
}
