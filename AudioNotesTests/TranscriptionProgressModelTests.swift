import Foundation
import Testing
@testable import AudioNotes

struct TranscriptionProgressModelTests {
    @Test func noEtaUntilACompletedPartProvidesMeasuredThroughput() {
        let start = Date(timeIntervalSince1970: 1_000)
        var tracker = TranscriptionProgressTracker(startedAt: start, totalAudioDuration: 600)
        tracker.setPhase(.transcribing, currentPart: 1, totalParts: 3)
        #expect(tracker.snapshot.estimatedRemainingTime == nil)
        #expect(tracker.snapshot.completedParts == 0)
        #expect(tracker.snapshot.processedAudioDuration == 0)

        tracker.completePart(audioDuration: 120, atElapsed: 60)
        #expect(tracker.snapshot.estimatedRemainingTime == 240)
        #expect(tracker.snapshot.completedParts == 1)
        #expect(tracker.snapshot.processedAudioDuration == 120)
    }

    @Test func cachedAudioAdvancesProgressWithoutInflatingThroughput() {
        var tracker = TranscriptionProgressTracker(startedAt: .now, totalAudioDuration: 300)
        tracker.apply(.init(phase: .transcribing, currentPart: 1, totalParts: 3, completedParts: 1,
                            processedAudioDuration: 100, totalAudioDuration: 300, reusedPart: true), elapsed: 2)
        #expect(tracker.snapshot.overallProgress == 1.0 / 3.0)
        #expect(tracker.snapshot.estimatedRemainingTime == nil)
        #expect(tracker.smoothedAudioSecondsPerWallSecond == nil)

        tracker.apply(.init(phase: .transcribing, currentPart: 2, totalParts: 3, completedParts: 2,
                            processedAudioDuration: 200, totalAudioDuration: 300), elapsed: 22)
        #expect(tracker.snapshot.estimatedRemainingTime == 20)
    }

    @Test func etaUsesUnevenPartDurationsAndSmoothsMeasuredRates() {
        let start = Date(timeIntervalSince1970: 2_000)
        var tracker = TranscriptionProgressTracker(startedAt: start, totalAudioDuration: 3_000, smoothingAlpha: 0.5)
        tracker.setPhase(.transcribing, currentPart: 1, totalParts: 3)
        tracker.completePart(audioDuration: 1_200, atElapsed: 60) // 20 min audio / 60 sec
        #expect(tracker.smoothedAudioSecondsPerWallSecond == 20)

        tracker.completePart(audioDuration: 1_800, atElapsed: 120) // 30 min audio / 60 sec
        #expect(tracker.smoothedAudioSecondsPerWallSecond == 25)
        #expect(tracker.snapshot.processedAudioDuration == 3_000)
        #expect(tracker.snapshot.estimatedRemainingTime == nil)
        #expect(tracker.snapshot.overallProgress == 1)
    }

    @Test func phaseProgressRemainsBoundedAndCompletes() {
        let start = Date(timeIntervalSince1970: 3_000)
        var tracker = TranscriptionProgressTracker(startedAt: start, totalAudioDuration: 100)
        tracker.setPhase(.transcribing, currentPart: 1, totalParts: 1)
        tracker.completePart(audioDuration: 100, atElapsed: 10)
        #expect(tracker.snapshot.overallProgress == 1)
        tracker.setPhase(.saving)
        #expect(tracker.snapshot.overallProgress == 1)
        tracker.setPhase(.completed)
        #expect(tracker.snapshot.overallProgress == 1)
        #expect(tracker.snapshot.estimatedRemainingTime == nil)
    }
}
