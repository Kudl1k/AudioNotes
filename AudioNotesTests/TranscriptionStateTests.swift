import Testing
@testable import AudioNotes

struct TranscriptionStateTests {
    @Test func activeAndTerminalStates() {
        for state in [TranscriptionState.preparing, .transcribing, .saving] {
            #expect(state.isProcessing)
        }
        for state in [TranscriptionState.idle, .completed, .failed(message: "Offline"), .cancelled] {
            #expect(!state.isProcessing)
            #expect(!state.canCancel)
        }
        #expect(TranscriptionState.preparing.canCancel)
        #expect(TranscriptionState.transcribing.canCancel)
        #expect(!TranscriptionState.saving.canCancel)
    }
}
