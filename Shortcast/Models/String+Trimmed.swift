import Foundation

extension String {
    /// Whitespace/newline-trimmed copy.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
