import Foundation

public struct MarkdownExporter: Sendable {
    public init() {}

    public func export(content: ExportContent, options: ExportOptions) -> String {
        var lines: [String] = []

        // YAML Front Matter
        if options.markdownFrontMatter {
            lines.append("---")
            lines.append("title: \"\(sanitizeYAML(content.title))\"")
            lines.append("date: \(ISO8601DateFormatter().string(from: content.recordedAt))")
            lines.append("duration: \"\(AudioTime.format(content.duration))\"")
            lines.append("original_file: \"\(sanitizeYAML(content.originalFileName))\"")
            lines.append("---")
            lines.append("")
        }

        // Title
        lines.append("# \(content.title)")
        lines.append("")

        // Metadata
        if options.includeMetadata && !options.markdownFrontMatter {
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short

            lines.append("**Date:** \(dateFormatter.string(from: content.recordedAt))  ")
            lines.append("**Duration:** \(AudioTime.format(content.duration))  ")
            lines.append("**Original File:** \(content.originalFileName)")
            lines.append("")
        }

        if options.includeAIGenerationMetadata && !content.aiGenerationMetadata.isEmpty {
            lines.append("## AI generation metadata")
            lines.append(contentsOf: content.aiGenerationMetadata.map { "- " + $0 })
            lines.append("")
        }

        if options.includeSources && !content.sourceNames.isEmpty {
            lines.append("## Sources")
            lines.append(contentsOf: content.sourceNames.map { "- " + $0 })
            lines.append("")
        }

        // Summary
        if options.includeSummary, let summary = content.summary {
            lines.append("## Summary (\(summary.presetTitle))")
            if !summary.title.isEmpty {
                lines.append("")
                lines.append("### \(summary.title)")
            }
            lines.append("")

            if !summary.sourceLabels.isEmpty {
                lines.append("Sources: " + summary.sourceLabels.map { "[" + $0 + "]" }.joined(separator: " "))
                lines.append("")
            }
            if !summary.overview.isEmpty {
                lines.append("### Overview")
                lines.append(summary.overview)
                lines.append("")
            }

            if !summary.keyPoints.isEmpty {
                lines.append("### Key Points")
                for point in summary.keyPoints {
                    lines.append("- \(point)")
                }
                lines.append("")
            }

            if !summary.decisions.isEmpty {
                lines.append("### Decisions")
                for decision in summary.decisions {
                    var line = "- \(decision.text)"
                    if options.includeTimestamps, let ts = decision.timestamp {
                        line += " `[\(AudioTime.format(ts))]`"
                    }
                    lines.append(line)
                }
                lines.append("")
            }

            if !summary.actionItems.isEmpty {
                lines.append("### Action Items")
                for item in summary.actionItems {
                    var details: [String] = []
                    if let assignee = item.assignee, !assignee.isEmpty {
                        details.append("Assignee: \(assignee)")
                    }
                    if let due = item.dueDate, !due.isEmpty {
                        details.append("Due: \(due)")
                    }
                    var line = "- [ ] \(item.text)"
                    if !details.isEmpty {
                        line += " (\(details.joined(separator: ", ")))"
                    }
                    if options.includeTimestamps, let ts = item.timestamp {
                        line += " `[\(AudioTime.format(ts))]`"
                    }
                    lines.append(line)
                }
                lines.append("")
            }

            if !summary.openQuestions.isEmpty {
                lines.append("### Open Questions")
                for question in summary.openQuestions {
                    lines.append("- \(question)")
                }
                lines.append("")
            }

            if !summary.importantQuotes.isEmpty {
                lines.append("### Important Quotes")
                for quote in summary.importantQuotes {
                    var citation = ""
                    if options.includeSpeakers, let speaker = quote.speaker, !speaker.isEmpty {
                        citation += " — *\(speaker)*"
                    }
                    if options.includeTimestamps, let ts = quote.timestamp {
                        citation += " `[\(AudioTime.format(ts))]`"
                    }
                    lines.append("> \"\(quote.text)\"\(citation)")
                    lines.append("")
                }
            }

            for section in summary.additionalSections where !section.items.isEmpty {
                lines.append("### \(section.title)")
                for item in section.items {
                    lines.append("- \(item)")
                }
                lines.append("")
            }
        }

        // Transcript
        if options.includeTranscript, let transcript = content.transcript, !transcript.segments.isEmpty {
            lines.append("## Transcript")
            lines.append("")

            for segment in transcript.segments {
                var prefix = ""
                if options.includeTimestamps {
                    prefix += "`[\(AudioTime.format(segment.startTime))]` "
                }
                if options.includeSpeakers, let speaker = segment.speaker, !speaker.isEmpty {
                    prefix += "**\(speaker):** "
                }
                lines.append("\(prefix)\(segment.text)")
                lines.append("")
            }
        }

        // Chat
        if options.includeChat && !content.chat.isEmpty {
            lines.append("## Chat History")
            lines.append("")

            for msg in content.chat {
                lines.append("### \(msg.role)")
                lines.append(msg.text)
                if !msg.sourceLabels.isEmpty { lines.append("Sources: " + msg.sourceLabels.map { "[" + $0 + "]" }.joined(separator: " ")) }
                if options.includeTimestamps && !msg.timestamps.isEmpty {
                    let tags = msg.timestamps.map { "`[\(AudioTime.format($0))]`" }.joined(separator: " ")
                    lines.append("")
                    lines.append("*Sources: \(tags)*")
                }
                lines.append("")
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func sanitizeYAML(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
