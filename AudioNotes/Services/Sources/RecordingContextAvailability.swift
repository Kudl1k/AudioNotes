import Foundation

/// Eligibility must not construct retrieval chunks or hash every source while typing.
@MainActor
enum RecordingContextAvailability {
    static func hasContent(_ recording: Recording, selectedSourceIDs: Set<UUID>? = nil) -> Bool {
        let primaryID = recording.sources.first(where: \.isPrimaryAudio)?.id ?? recording.id
        if selectedSourceIDs?.contains(primaryID) ?? true,
           recording.transcript?.segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true {
            return true
        }
        return recording.sources.contains { source in
            guard !source.isPrimaryAudio, source.isContextReady, selectedSourceIDs?.contains(source.id) ?? true else { return false }
            if source.type == .image { return true } // Includes explicitly usable text-free images.
            if source.type == .audio {
                return source.transcript?.segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
            }
            return source.textUnits.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.locator != nil }
        }
    }

    /// Same selection metadata as RecordingContextSnapshot, without derived content.
    static func readySourceIDs(_ recording: Recording, selectedSourceIDs: Set<UUID>? = nil) -> Set<UUID> {
        let primaryID = recording.sources.first(where: \.isPrimaryAudio)?.id ?? recording.id
        var ids = Set(recording.sources.filter { !$0.isPrimaryAudio && $0.isContextReady }.map(\.id))
        if recording.transcript?.segments.isEmpty == false { ids.insert(primaryID) }
        return selectedSourceIDs.map { ids.intersection($0) } ?? ids
    }
}
