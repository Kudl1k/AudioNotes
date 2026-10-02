import Foundation

/// Operation durations use m:ss below an hour and h:mm:ss thereafter.
/// Audio locations retain their separate timestamp convention.
enum OperationDurationFormatter {
    static func elapsed(since start: Date, now: Date) -> TimeInterval {
        let duration = now.timeIntervalSince(start)
        return duration.isFinite ? max(0, duration) : 0
    }

    static func string(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
        let value = Int(seconds.rounded(.down))
        if value >= 3600 {
            return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
        }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
