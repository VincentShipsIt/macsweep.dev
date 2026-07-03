import SwiftUI

extension Binding {
    /// `true` while the wrapped optional holds a value; setting `false` clears it.
    /// Backs `.errorAlert` so alert presentation derives from the optional message
    /// itself instead of a hand-rolled `Binding(get:set:)` at every call site.
    func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(
            get: { self.wrappedValue != nil },
            set: { if !$0 { self.wrappedValue = nil } }
        )
    }
}

extension View {
    /// Presents a dismissable alert whenever `message` is non-nil, clearing the
    /// message on dismiss. The single feedback surface for cleanup failures.
    func errorAlert(_ title: String = "Error", message: Binding<String?>) -> some View {
        alert(title, isPresented: message.isPresent()) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
