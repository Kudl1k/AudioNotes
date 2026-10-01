import Foundation
import Observation

@MainActor
@Observable
final class ExportViewModel {
    enum State: Equatable { case idle, choosingDestination, exporting, completed, failed(String) }
    private(set) var state = State.idle
    var isBusy: Bool { state == .choosingDestination || state == .exporting }
    var errorMessage: String? { if case .failed(let message) = state { message } else { nil } }
    @ObservationIgnored private let service: any ExportWriting
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var attemptID: UUID?

    init(service: any ExportWriting = NativeExportService()) { self.service = service }
    func chooseDestination() -> Bool {
        guard !isBusy else { return false }
        state = .choosingDestination
        return true
    }
    @discardableResult func export(recording: Recording, options: ExportOptions, to url: URL) -> Task<Void, Never>? {
        guard state == .choosingDestination else { return nil }
        state = .exporting
        let id = UUID()
        attemptID = id
        let service = service
        task = Task { [weak self] in
            do {
                await Task.yield()
                try Task.checkCancellation()
                let content = ExportContentBuilder.build(from: recording)
                try await service.write(content: content, options: options, to: url)
                try Task.checkCancellation()
                guard let self, self.attemptID == id else { return }
                self.state = .completed
            } catch {
                guard let self, self.attemptID == id else { return }
                self.state = error is CancellationError ? .idle : .failed("Could not export: " + error.localizedDescription)
            }
            if self?.attemptID == id { self?.task = nil; self?.attemptID = nil }
        }
        return task
    }
    func cancel() {
        attemptID = nil
        task?.cancel(); task = nil
        state = .idle
    }
}
