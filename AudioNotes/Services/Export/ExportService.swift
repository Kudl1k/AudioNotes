import Foundation

protocol ExportWriting: Sendable {
    func write(content: ExportContent, options: ExportOptions, to url: URL) async throws
}

struct NativeExportService: ExportWriting {
    func write(content: ExportContent, options: ExportOptions, to url: URL) async throws {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let interval = PerformanceSignposts.begin("Export render and write")
            defer { PerformanceSignposts.end("Export render and write", interval) }
            let data: Data
            switch options.format {
            case .markdown: data = Data(MarkdownExporter().export(content: content, options: options).utf8)
            case .pdf: data = try PDFExporter().exportCancellable(content: content, options: options)
            }
            try Task.checkCancellation()
            guard !data.isEmpty else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
