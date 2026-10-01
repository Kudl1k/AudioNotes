import Foundation
import UniformTypeIdentifiers
import SwiftUI

/// A private drag payload: recordings stay in the library and only their stable identity is transferred.
struct RecordingDragItem: Codable, Hashable, Sendable, Transferable {
    let recordingID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .audioNotesRecording)
    }
}

extension UTType {
    static let audioNotesRecording = UTType(exportedAs: "com.audionotes.recording-reference", conformingTo: .data)
}
