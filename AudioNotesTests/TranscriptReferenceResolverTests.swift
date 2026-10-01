import Foundation
import Testing
@testable import AudioNotes

@Suite struct TranscriptReferenceResolverTests {

    @Test func resolvesValidReferencesInChronologicalOrder() {
        let seg1ID = UUID()
        let seg2ID = UUID()
        let seg3ID = UUID()

        let snapshots = [
            TranscriptSegmentSnapshot(id: seg1ID, startTime: 10.0, endTime: 25.0, speaker: "Speaker 1", text: "First topic discussed."),
            TranscriptSegmentSnapshot(id: seg2ID, startTime: 30.0, endTime: 45.0, speaker: nil, text: "Second topic debated."),
            TranscriptSegmentSnapshot(id: seg3ID, startTime: 50.0, endTime: 70.0, speaker: "Speaker 2", text: "Final conclusion made.")
        ]

        let resolver = TranscriptReferenceResolver()

        // Passed out of order: seg3, seg1
        let cited = [seg3ID.uuidString, seg1ID.uuidString]
        let resolved = resolver.resolve(segmentIDs: cited, against: snapshots)

        #expect(resolved.count == 2)
        // Should be sorted chronologically: seg1 then seg3
        #expect(resolved[0].segmentID == seg1ID)
        #expect(resolved[0].startTime == 10.0)
        #expect(resolved[0].endTime == 25.0)
        #expect(resolved[0].speaker == "Speaker 1")
        #expect(resolved[0].excerpt == "First topic discussed.")
        #expect(resolved[0].label == "00:10 — Speaker 1")

        #expect(resolved[1].segmentID == seg3ID)
        #expect(resolved[1].startTime == 50.0)
        #expect(resolved[1].endTime == 70.0)
        #expect(resolved[1].speaker == "Speaker 2")
        #expect(resolved[1].label == "00:50 — Speaker 2")
    }

    @Test func stripsHallucinatedIDsAndDeduplicates() {
        let segID = UUID()
        let hallucinatedID = UUID()

        let snapshots = [
            TranscriptSegmentSnapshot(id: segID, startTime: 125.0, endTime: 135.0, speaker: "Alice", text: "Important fact.")
        ]

        let resolver = TranscriptReferenceResolver()
        // Cite the same valid segment twice and one non-existent hallucinated UUID
        let cited = [segID.uuidString, hallucinatedID.uuidString, segID.uuidString]
        let resolved = resolver.resolve(segmentIDs: cited, against: snapshots)

        #expect(resolved.count == 1)
        #expect(resolved[0].segmentID == segID)
        #expect(resolved[0].label == "02:05 — Alice")
    }

    @Test func truncatesLongExcerptsGracefully() {
        let segID = UUID()
        let longText = String(repeating: "Antigravity voice transcription notes. ", count: 10)

        let snapshots = [
            TranscriptSegmentSnapshot(id: segID, startTime: 0.0, endTime: 10.0, speaker: nil, text: longText)
        ]

        let resolver = TranscriptReferenceResolver()
        let resolved = resolver.resolve(segmentIDs: [segID.uuidString], against: snapshots)

        #expect(resolved.count == 1)
        #expect((resolved[0].excerpt?.count ?? 0) <= 125)
        #expect(resolved[0].excerpt?.hasSuffix("...") == true)
    }
}
