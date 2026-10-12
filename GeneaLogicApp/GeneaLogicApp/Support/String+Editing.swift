import Foundation

extension String {
    /// Trimmed of surrounding whitespace and newlines.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The trimmed value, or `nil` if it's empty after trimming — for mapping a
    /// text field onto an optional model field (empty box → no value).
    var trimmedNonEmpty: String? { trimmed.isEmpty ? nil : trimmed }
}
