import AppKit
import PDFKit
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
            case .pdf: NativePDFPreview(url: url, locator: target.locator)
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
                if case .audio(_, let start, _) = target.locator { playback.seek(to: start) }
            }
        }
        .onDisappear { playback.stop() }
    }
    private var documentText: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(target.source.textUnits.sorted { $0.position < $1.position }) { unit in
                        Text(unit.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).id(unit.id)
                    }
                }.padding(20)
            }.onAppear {
                if case .document(_, let start, _) = target.locator,
                   let unit = target.source.textUnits.first(where: {
                       if case .document(_, let lower, let upper) = $0.locator { return start >= lower && start < upper }
                       return false
                   }) { proxy.scrollTo(unit.id, anchor: .top) }
            }
        }
    }
}

private final class ReadOnlyPDFView: PDFView {
    // Imported PDF actions never launch URLs, embedded files, scripts, or applications.
    override func perform(_ action: PDFAction) {
        if action is PDFActionGoTo { super.perform(action) }
    }
}
private struct NativePDFPreview: NSViewRepresentable {
    let url: URL
    let locator: SourceLocator?
    func makeNSView(context: Context) -> PDFView {
        let view = ReadOnlyPDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if case .pdf(let index) = locator, let page = view.document?.page(at: index) { view.go(to: page) }
    }
}
