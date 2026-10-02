import SwiftUI

struct SourcePreviewTarget: Identifiable {
    let source: RecordingSource
    var locator: SourceLocator?
    var id: UUID { source.id }
}

struct SourcePreviewView: View {
    let target: SourcePreviewTarget
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var playback = AudioPlaybackService()
    @State private var previewImage: CGImage?
    @State private var loadingImage = true
    private let imageLoader = SourceImageLoader()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(target.source.displayName).font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            Divider()
            switch target.source.type {
#if os(macOS)
            case .pdf: PDFPreviewRepresentable(url: url, locator: target.locator)
#else
            case .pdf: ContentUnavailableView("PDF Preview", systemImage: "doc.text", description: Text("PDF preview arrives in M16.5."))
#endif
            case .image:
                if let image = previewImage {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().padding()
                } else if loadingImage { ProgressView("Opening image…") }
                else { ContentUnavailableView("Image unavailable", systemImage: "photo", description: Text("The source file may be missing or unreadable.")) }
            case .document: documentText
            case .audio:
                PlaybackControls(playback: playback).padding()
                TranscriptView(transcript: target.source.authoritativeTranscript) { playback.seek(to: $0) }
            }
        }
        .frame(minWidth: 580, idealWidth: 800, minHeight: 500, idealHeight: 650)
        .task(id: url) {
            guard target.source.type == .image else { return }
            loadingImage = true
            let image = await imageLoader.image(url: url, maximumDimension: 2400)
            guard !Task.isCancelled else { return }
            previewImage = image
            loadingImage = false
        }
        .onAppear {
            if target.source.type == .audio {
                playback.load(url: url)
            }
        }
        .onDisappear { playback.stop() }
    }

    private var documentText: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(target.source.textUnits.sorted { $0.position < $1.position }) { unit in
                    Text(unit.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding()
        }
    }
}
