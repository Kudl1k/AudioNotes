import Foundation
import Testing
@testable import AudioNotes

struct SummaryPresetTests {
    @Test func presetsHaveIconsAndNonEmptyInstructions() {
        for preset in SummaryPreset.allCases {
            #expect(!preset.title.isEmpty)
            #expect(!preset.iconName.isEmpty)
            #expect(!preset.systemInstructions.isEmpty)
        }
    }

    @Test func presetsCodableRoundTrip() throws {
        for preset in SummaryPreset.allCases {
            let data = try JSONEncoder().encode(preset)
            let decoded = try JSONDecoder().decode(SummaryPreset.self, from: data)
            #expect(decoded == preset)
        }
    }
}
