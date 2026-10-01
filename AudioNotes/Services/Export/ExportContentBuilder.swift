import Foundation

@MainActor
struct ExportContentBuilder {
    static func build(from recording: Recording) -> ExportContent {
        let references = (recording.summary?.sourceReferences ?? []) + (recording.chatSessions.first?.messages.flatMap(\.sourceReferences) ?? [])
        let chunks = references.isEmpty ? [] : RecordingContextSnapshot(recording: recording, selectedSourceIDs: Set(references.map(\.sourceID))).chunks
        let referenceIndex = SourceReferenceIndex(chunks: chunks)
        let exportTranscript: ExportTranscript? = recording.transcript.map { transcript in
            let sortedSegments = transcript.segments.sorted { $0.startTime < $1.startTime }
            return ExportTranscript(
                segments: sortedSegments.map {
                    ExportTranscriptSegment(
                        startTime: $0.startTime,
                        endTime: $0.endTime,
                        speaker: $0.speaker,
                        text: $0.text
                    )
                }
            )
        }

        let exportSummary: ExportSummary? = recording.summary.map { summary in
            var result = ExportSummary(
                presetTitle: summary.preset.title,
                overview: summary.overview,
                keyPoints: summary.keyPoints.map(\.text),
                decisions: summary.decisions.map {
                    ExportSummaryDecision(text: $0.text, timestamp: $0.timestamp)
                },
                actionItems: summary.actionItems.map {
                    ExportSummaryActionItem(
                        text: $0.text,
                        assignee: $0.assignee,
                        dueDate: $0.dueDate,
                        timestamp: $0.timestamp
                    )
                },
                openQuestions: summary.openQuestions.map(\.text),
                importantQuotes: summary.importantQuotes.map {
                    ExportSummaryQuote(text: $0.text, speaker: $0.speaker, timestamp: $0.timestamp)
                },
                additionalSections: summary.additionalSections.map {
                    (title: $0.title, items: $0.items)
                }
            )
            result.title = summary.title
            result.sourceLabels = SourceReferencePresentation.labels(referenceIndex.validate(summary.sourceReferences))
            return result
        }

        let chatMessages: [ExportChatMessage] = recording.chatSessions.first.map { session in
            session.orderedMessages.map { msg in
                var result = ExportChatMessage(
                    role: msg.role.rawValue.capitalized,
                    text: msg.text,
                    timestamps: msg.references.map(\.startTime),
                    sentAt: msg.createdAt
                )
                result.sourceLabels = SourceReferencePresentation.labels(referenceIndex.validate(msg.sourceReferences))
                return result
            }
        } ?? []

        var content = ExportContent(
            title: recording.title,
            originalFileName: recording.originalFileName,
            duration: recording.duration,
            recordedAt: recording.importedAt,
            transcript: exportTranscript,
            summary: exportSummary,
            chat: chatMessages
        )
        content.sourceNames = recording.sources.sorted { $0.importedAt < $1.importedAt }.map(\.displayName)
        content.aiGenerationMetadata = recording.generationRecords.sorted { $0.startedAt < $1.startedAt }.map {
            "\($0.featureRaw.capitalized): \($0.usageDetails)"
        }
        return content
    }
}
