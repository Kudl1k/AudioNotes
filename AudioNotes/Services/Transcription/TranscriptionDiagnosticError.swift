import Foundation

/// Optional safe details for support. Providers must exclude credentials and raw responses.
protocol TranscriptionDiagnosticError: Error {
    var diagnosticDetails: String { get }
}
