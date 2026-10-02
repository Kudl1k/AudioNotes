import SwiftData
import SwiftUI

/// Identity of the generation data that library cost totals depend on. Hashing the fields
/// avoids building and joining a string per record.
struct UsageRefreshKey: Hashable {
    let count: Int
    let digest: Int

    init(_ records: [GenerationRecord]) {
        var hasher = Hasher()
        for record in records {
            hasher.combine(record.id)
            hasher.combine(record.statusRaw)
            hasher.combine(record.requestUsageData)
        }
        count = records.count
        digest = hasher.finalize()
    }
}

/// Owns the generation query so the O(n) key is evaluated when generation records change,
/// not whenever LibraryView re-renders for selection or transcription progress.
struct UsageSnapshotRefresher: View, Equatable {
    @Query private var generations: [GenerationRecord]
    @Binding var costs: UsageDashboardSnapshot

    // The binding is the only input and never changes identity; query changes invalidate independently.
    static func == (lhs: Self, rhs: Self) -> Bool { true }

    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .task(id: UsageRefreshKey(generations)) { costs = UsageRepository().snapshot(records: generations) }
    }
}
