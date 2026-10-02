import Foundation

enum TranscriptionPhase: String, Sendable, CaseIterable {
    case preparing, splitting, transcribing, merging, saving, completed

    var message: String {
        switch self {
        case .preparing: "Preparing audio…"
        case .splitting: "Splitting recording…"
        case .transcribing: "Transcribing audio…"
        case .merging: "Combining transcript…"
        case .saving: "Saving transcript…"
        case .completed: "Transcription complete"
        }
    }
}

struct TranscriptionProgressSnapshot: Equatable, Sendable {
    var phase: TranscriptionPhase
    var startedAt: Date
    var currentPart: Int?
    var totalParts: Int?
    var completedParts: Int
    var processedAudioDuration: TimeInterval?
    var totalAudioDuration: TimeInterval?
    var overallProgress: Double?
    var estimatedRemainingTime: TimeInterval?

    var partDescription: String? {
        guard let currentPart, let totalParts, totalParts > 0, currentPart > 0, currentPart <= totalParts else { return nil }
        return "Part \(currentPart) of \(totalParts)"
    }
}

/// Tracks measured part throughput; callers only complete a part after its result arrives.
struct TranscriptionProgressTracker: Sendable {
    private(set) var snapshot: TranscriptionProgressSnapshot
    private(set) var smoothedAudioSecondsPerWallSecond: Double?
    private var previousCompletedAudio: TimeInterval = 0
    private var previousCompletedElapsed: TimeInterval = 0
    private let smoothingAlpha: Double

    init(startedAt: Date, totalAudioDuration: TimeInterval, smoothingAlpha: Double = 0.35) {
        let start = startedAt
        self.smoothingAlpha = min(1, max(0, smoothingAlpha))
        snapshot = TranscriptionProgressSnapshot(phase: .preparing, startedAt: start,
            currentPart: nil, totalParts: nil, completedParts: 0,
            processedAudioDuration: 0, totalAudioDuration: totalAudioDuration > 0 ? totalAudioDuration : nil,
            overallProgress: nil, estimatedRemainingTime: nil)
    }

    mutating func setPhase(_ phase: TranscriptionPhase, currentPart: Int? = nil, totalParts: Int? = nil) {
        snapshot.phase = phase
        snapshot.currentPart = currentPart
        snapshot.totalParts = totalParts
        if phase != .transcribing { snapshot.estimatedRemainingTime = nil }
        if phase == .completed { snapshot.overallProgress = 1; snapshot.estimatedRemainingTime = nil }
    }

    mutating func apply(_ status: TranscriptionStatus, elapsed: TimeInterval) {
        if status.totalAudioDuration > 0 { snapshot.totalAudioDuration = status.totalAudioDuration }
        if status.completedParts == 0, status.totalParts == nil, status.processedAudioDuration > (snapshot.processedAudioDuration ?? 0) {
            let delta = status.processedAudioDuration - (snapshot.processedAudioDuration ?? 0)
            completePart(audioDuration: delta, atElapsed: elapsed)
            if let total = snapshot.totalAudioDuration { snapshot.overallProgress = min(1, status.processedAudioDuration / total) }
        }
        if status.completedParts > snapshot.completedParts {
            let newlyProcessed = status.processedAudioDuration - (snapshot.processedAudioDuration ?? 0)
            completePart(audioDuration: newlyProcessed, atElapsed: elapsed)
        }
        snapshot.completedParts = status.totalParts == nil ? status.completedParts : max(snapshot.completedParts, status.completedParts)
        snapshot.processedAudioDuration = status.processedAudioDuration
        setPhase(status.phase, currentPart: status.currentPart, totalParts: status.totalParts)
    }

    mutating func completePart(audioDuration: TimeInterval, atElapsed elapsed: TimeInterval) {
        guard audioDuration > 0, audioDuration.isFinite else { return }
        snapshot.completedParts += 1
        previousCompletedAudio += audioDuration
        snapshot.processedAudioDuration = previousCompletedAudio
        let wall = elapsed - previousCompletedElapsed
        if wall > 0 {
            let rate = audioDuration / wall
            if rate.isFinite, rate > 0 {
                smoothedAudioSecondsPerWallSecond = smoothedAudioSecondsPerWallSecond.map {
                    smoothingAlpha * rate + (1 - smoothingAlpha) * $0
                } ?? rate
            }
        }
        previousCompletedElapsed = elapsed
        if let total = snapshot.totalAudioDuration, total > 0 {
            snapshot.overallProgress = min(1, previousCompletedAudio / total)
            if let rate = smoothedAudioSecondsPerWallSecond, previousCompletedAudio < total {
                snapshot.estimatedRemainingTime = max(0, total - previousCompletedAudio) / rate
            } else {
                snapshot.estimatedRemainingTime = nil
            }
        }
    }
}

enum TranscriptionPartState: Sendable { case pending, active, completed }
