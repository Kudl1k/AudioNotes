#if os(macOS)
import SwiftUI

struct WelcomeView: View {
    let complete: (_ openSettings: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Welcome to Soniquill", systemImage: "waveform").font(.largeTitle)
            Text("Turn recordings and documents into transcripts, summaries and useful notes.")
            GroupBox("Choose your AI setup") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Cloud AI").font(.headline)
                    Text("Configure a supported provider in Settings. Audio and relevant content are sent to the provider you choose. API access may be billed separately from consumer subscriptions.")
                    Text("Local AI").font(.headline)
                    Text("Download a Local Whisper model for transcription on this Mac. Connect a separately installed Ollama server for summaries and chat. Local Only blocks external AI processing; model downloads and update checks still use the internet.")
                }.padding(8)
            }
            Text("Start by importing a recording, or create a project to add documents. Your library is stored on this Mac. You can change setup later in Settings.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Set Up Later") { complete(false) }
                Spacer()
                Button("Open Settings") { complete(true) }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 600)
    }
}

struct WelcomePresentation: ViewModifier {
    @AppStorage("onboarding.completed.v1") private var completed = false
    @State private var presented = false
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onAppear {
#if DEBUG
            guard NSClassFromString("XCTestCase") == nil,
                  !ProcessInfo.processInfo.arguments.contains("--performance-fixtures"),
                  !ProcessInfo.processInfo.arguments.contains("--performance-empty-library") else { return }
#endif
            presented = !completed
        }.sheet(isPresented: $presented) {
            WelcomeView { showSettings in
                completed = true
                presented = false
                if showSettings { openSettings() }
            }
        }
    }
}

#endif
