import Foundation

enum AudioTime {
    static func string(_ seconds: TimeInterval) -> String {
        let wholeSeconds = seconds.isFinite ? max(0, seconds.rounded(.down)) : 0
        return Duration.seconds(wholeSeconds)
            .formatted(.time(pattern: wholeSeconds >= 3_600 ? .hourMinuteSecond : .minuteSecond))
    }

    static func format(_ seconds: TimeInterval) -> String {
        TimestampFormatter.string(seconds)
    }
}
