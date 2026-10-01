#if DEBUG
import AppKit
import SwiftData
import SwiftUI

/// A fresh development window avoids depending on the user's saved scene identifiers.
/// Used only by explicit performance launch arguments, never by the shipping app.
@MainActor
final class PerformanceFixtureApplicationDelegate: NSObject, NSApplicationDelegate {
    private var fixtureWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--performance-fixtures") || arguments.contains("--performance-empty-library") else { return }
        do {
            let container = try LibraryStorage().makeContainer(inMemory: true)
            let content: AnyView
            if arguments.contains("--performance-fixtures") {
                content = AnyView(PerformanceFixtureLibrary().modelContainer(container).environment(LocalAIConfiguration()))
            } else {
                content = AnyView(LibraryView(transcriptionResolver: FixedTranscriptionProviderResolver(provider: MockTranscriptionProvider()),
                    llmResolver: FixedLLMProviderResolver(provider: MockLLMProvider())).modelContainer(container).environment(LocalAIConfiguration()))
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "AudioNotes · Development Fixtures"
            window.minSize = NSSize(width: 760, height: 500)
            window.contentView = NSHostingView(rootView: content.frame(minWidth: 760, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity))
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            fixtureWindow = window
        } catch {
            assertionFailure("Could not create the isolated development fixture window: \(error)")
        }
    }
}
#endif
