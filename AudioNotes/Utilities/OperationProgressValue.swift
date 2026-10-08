import Foundation

/// A display value, not an operation owner. Unknown totals stay indeterminate.
struct OperationProgressValue: Equatable, Sendable {
    let fraction: Double?
    let completed: Int?
    let total: Int?

    init(fraction: Double? = nil, completed: Int? = nil, total: Int? = nil) {
        if let completed, let total, total > 0 {
            self.completed = min(total, max(0, completed))
            self.total = total
        } else {
            self.completed = nil
            self.total = nil
        }
        if let fraction, fraction.isFinite {
            self.fraction = min(1, max(0, fraction))
        } else if fraction == nil, let completed = self.completed, let total = self.total {
            self.fraction = Double(completed) / Double(total)
        } else { self.fraction = nil }
    }

    var percentage: String? { fraction.map { "\(Int(($0 * 100).rounded(.down)))%" } }
}

