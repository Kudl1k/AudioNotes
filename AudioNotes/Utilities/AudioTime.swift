import Foundation

enum AudioTime {
    static func string(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.isFinite ? max(0, seconds) : 0)
            .formatted(.time(pattern: .minuteSecond))
    }
}
