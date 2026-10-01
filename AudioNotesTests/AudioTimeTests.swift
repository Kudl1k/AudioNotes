import Foundation
import Testing
@testable import AudioNotes

struct AudioTimeTests {
    @Test(arguments: [
        (0.0, "0:00"), (9.9, "0:09"), (59.99, "0:59"),
        (60.0, "1:00"), (3_599.0, "59:59"), (3_600.0, "1:00:00"),
        (3_661.0, "1:01:01"), (36_001.0, "10:00:01"),
        (-1.0, "0:00"), (Double.nan, "0:00"), (Double.infinity, "0:00")
    ])
    func formatsAudioTimestamps(input: Double, expected: String) {
        #expect(AudioTime.string(input) == expected)
    }
}
