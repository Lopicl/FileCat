import SwiftUI

extension Binding where Value == Bool {
    /// `true` while `value` is non-nil; setting `false` clears it. Handy for alerts and sheets.
    init<T: Sendable>(isPresenting value: Binding<T?>) {
        self.init {
            value.wrappedValue != nil
        } set: { isPresented in
            if !isPresented { value.wrappedValue = nil }
        }
    }
}
