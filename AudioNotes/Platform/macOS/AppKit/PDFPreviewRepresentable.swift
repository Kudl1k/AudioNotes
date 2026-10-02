#if os(macOS)
import PDFKit
import SwiftUI

private final class ReadOnlyPDFView: PDFView {
    // Imported PDF actions never launch URLs, embedded files, scripts, or applications.
    override func perform(_ action: PDFAction) {
        if action is PDFActionGoTo { super.perform(action) }
    }
}

/// PDFKit owns rendering, selection, Find and scrolling; SwiftUI owns placement.
struct PDFPreviewRepresentable: NSViewRepresentable {
    let url: URL
    let locator: SourceLocator?

    final class Coordinator {
        var appliedLocator: SourceLocator?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = ReadOnlyPDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        // Jump only when the requested location changes, so unrelated SwiftUI updates
        // never pull the reader back to the cited page.
        guard locator != context.coordinator.appliedLocator else { return }
        context.coordinator.appliedLocator = locator
        if case .pdf(let index) = locator, let page = view.document?.page(at: index) { view.go(to: page) }
    }
}
#endif
