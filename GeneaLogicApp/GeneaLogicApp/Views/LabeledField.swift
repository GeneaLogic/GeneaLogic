import SwiftUI

/// A stacked label + field, matching the editor sheets' left-aligned layout. Shared
/// by the assertion editor (events/places/persons mentioned) and the person editor
/// (names/facts).
struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content
                .textFieldStyle(.roundedBorder)
        }
    }
}
