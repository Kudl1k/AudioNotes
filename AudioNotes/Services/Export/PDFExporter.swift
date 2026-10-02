#if os(macOS)
import AppKit
import CoreGraphics
import CoreText
import Foundation

public struct PDFExporter: Sendable {
    public init() {}

    public func export(content: ExportContent, options: ExportOptions) -> Data {
        let attrString = buildAttributedString(content: content, options: options)
        return (try? renderPDF(from: attrString, title: content.title)) ?? Data()
    }

    func exportCancellable(content: ExportContent, options: ExportOptions) throws -> Data {
        try Task.checkCancellation()
        let text = buildAttributedString(content: content, options: options)
        try Task.checkCancellation()
        return try renderPDF(from: text, title: content.title, cancellationCheck: { try Task.checkCancellation() })
    }

    private func buildAttributedString(content: ExportContent, options: ExportOptions) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let titleFont = NSFont.systemFont(ofSize: 22, weight: .bold)
        let h2Font = NSFont.systemFont(ofSize: 15, weight: .bold)
        let h3Font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        let bodyBoldFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let italicFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
        let monoFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)

        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.paragraphSpacing = 8
        titleParagraph.lineSpacing = 2

        let h2Paragraph = NSMutableParagraphStyle()
        h2Paragraph.paragraphSpacingBefore = 14
        h2Paragraph.paragraphSpacing = 6

        let h3Paragraph = NSMutableParagraphStyle()
        h3Paragraph.paragraphSpacingBefore = 10
        h3Paragraph.paragraphSpacing = 4

        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.paragraphSpacing = 5
        bodyParagraph.lineSpacing = 2

        let bulletParagraph = NSMutableParagraphStyle()
        bulletParagraph.firstLineHeadIndent = 0
        bulletParagraph.headIndent = 14
        bulletParagraph.paragraphSpacing = 4

        let quoteParagraph = NSMutableParagraphStyle()
        quoteParagraph.firstLineHeadIndent = 12
        quoteParagraph.headIndent = 12
        quoteParagraph.paragraphSpacing = 6

        // Title
        result.append(NSAttributedString(
            string: content.title + "\n",
            attributes: [
                .font: titleFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: titleParagraph
            ]
        ))

        // Metadata
        if options.includeMetadata {
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short

            let metaText = "Date: \(dateFormatter.string(from: content.recordedAt))  •  Duration: \(AudioTime.format(content.duration))  •  File: \(content.originalFileName)\n\n"
            result.append(NSAttributedString(
                string: metaText,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: bodyParagraph
                ]
            ))
        }

        if options.includeAIGenerationMetadata && !content.aiGenerationMetadata.isEmpty {
            result.append(NSAttributedString(string: "AI generation metadata\n" + content.aiGenerationMetadata.joined(separator: "\n") + "\n",
                attributes: [.font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: bodyParagraph]))
        }

        if options.includeSources && !content.sourceNames.isEmpty {
            result.append(NSAttributedString(string: "Sources\n", attributes: [.font: h2Font, .paragraphStyle: h2Paragraph]))
            result.append(NSAttributedString(string: content.sourceNames.joined(separator: "\n") + "\n", attributes: [.font: bodyFont, .paragraphStyle: bodyParagraph]))
        }

        // Summary
        if options.includeSummary, let summary = content.summary {
            result.append(NSAttributedString(
                string: "Summary (\(summary.presetTitle))\n",
                attributes: [
                    .font: h2Font,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: h2Paragraph
                ]
            ))

            if !summary.title.isEmpty {
                result.append(NSAttributedString(string: summary.title + "\n",
                    attributes: [.font: h3Font, .foregroundColor: NSColor.labelColor, .paragraphStyle: h3Paragraph]))
            }
            if !summary.sourceLabels.isEmpty {
                result.append(NSAttributedString(string: "Sources: " + summary.sourceLabels.joined(separator: "; ") + "\n",
                    attributes: [.font: bodyFont, .paragraphStyle: bodyParagraph]))
            }
            if !summary.overview.isEmpty {
                result.append(NSAttributedString(
                    string: "Overview\n",
                    attributes: [.font: h3Font, .foregroundColor: NSColor.labelColor, .paragraphStyle: h3Paragraph]
                ))
                result.append(NSAttributedString(
                    string: summary.overview + "\n",
                    attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: bodyParagraph]
                ))
            }

            if !summary.keyPoints.isEmpty {
                result.append(NSAttributedString(
                    string: "Key Points\n",
                    attributes: [.font: h3Font, .foregroundColor: NSColor.labelColor, .paragraphStyle: h3Paragraph]
                ))
                for point in summary.keyPoints {
                    result.append(NSAttributedString(
                        string: "•  \(point)\n",
                        attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: bulletParagraph]
                    ))
                }
            }

            if !summary.decisions.isEmpty {
                result.append(NSAttributedString(
                    string: "Decisions\n",
                    attributes: [.font: h3Font, .foregroundColor: NSColor.labelColor, .paragraphStyle: h3Paragraph]
                ))
                for decision in summary.decisions {
                    let itemString = NSMutableAttributedString(
                        string: "✓  \(decision.text)",
                        attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: bulletParagraph]
                    )
                    if options.includeTimestamps, let ts = decision.timestamp {
                        itemString.append(NSAttributedString(
                            string: " [\(AudioTime.format(ts))]",
                            attributes: [.font: monoFont, .foregroundColor: NSColor.secondaryLabelColor]
                        ))
                    }
                    itemString.append(NSAttributedString(string: "\n"))
                    result.append(itemString)
                }
            }

            if !summary.actionItems.isEmpty {
                result.append(NSAttributedString(
                    string: "Action Items\n",
                    attributes: [.font: h3Font, .foregroundColor: NSColor.labelColor, .paragraphStyle: h3Paragraph]
                ))
                for item in summary.actionItems {
                    var details: [String] = []
                    if let assignee = item.assignee, !assignee.isEmpty { details.append("Assignee: \(assignee)") }
                    if let due = item.dueDate, !due.isEmpty { details.append("Due: \(due)") }
                    var text = "□  \(item.text)"
                    if !details.isEmpty { text += " (\(details.joined(separator: ", ")))" }
                    let itemString = NSMutableAttributedString(
                        string: text,
                        attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: bulletParagraph]
                    )
                    if options.includeTimestamps, let ts = item.timestamp {
                        itemString.append(NSAttributedString(
                            string: " [\(AudioTime.format(ts))]",
                            attributes: [.font: monoFont, .foregroundColor: NSColor.secondaryLabelColor]
                        ))
                    }
                    itemString.append(NSAttributedString(string: "\n"))
                    result.append(itemString)
                }
            }

            if !summary.openQuestions.isEmpty {
                result.append(NSAttributedString(
                    string: "Open Questions\n",
                    attributes: [.font: h3Font, .foregroundColor: NSColor.labelColor, .paragraphStyle: h3Paragraph]
                ))
                for question in summary.openQuestions {
                    result.append(NSAttributedString(
                        string: "?  \(question)\n",
                        attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: bulletParagraph]
                    ))
                }
            }

            if !summary.importantQuotes.isEmpty {
                result.append(NSAttributedString(
                    string: "Important Quotes\n",
                    attributes: [.font: h3Font, .foregroundColor: NSColor.labelColor, .paragraphStyle: h3Paragraph]
                ))
                for quote in summary.importantQuotes {
                    let quoteStr = NSMutableAttributedString(
                        string: "“\(quote.text)”",
                        attributes: [.font: italicFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: quoteParagraph]
                    )
                    if options.includeSpeakers, let speaker = quote.speaker, !speaker.isEmpty {
                        quoteStr.append(NSAttributedString(
                            string: " — \(speaker)",
                            attributes: [.font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor]
                        ))
                    }
                    if options.includeTimestamps, let ts = quote.timestamp {
                        quoteStr.append(NSAttributedString(
                            string: " [\(AudioTime.format(ts))]",
                            attributes: [.font: monoFont, .foregroundColor: NSColor.secondaryLabelColor]
                        ))
                    }
                    quoteStr.append(NSAttributedString(string: "\n\n"))
                    result.append(quoteStr)
                }
            }

            for section in summary.additionalSections where !section.items.isEmpty {
                result.append(NSAttributedString(
                    string: "\(section.title)\n",
                    attributes: [.font: h3Font, .foregroundColor: NSColor.labelColor, .paragraphStyle: h3Paragraph]
                ))
                for item in section.items {
                    result.append(NSAttributedString(
                        string: "•  \(item)\n",
                        attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: bulletParagraph]
                    ))
                }
            }
        }

        // Transcript
        if options.includeTranscript, let transcript = content.transcript, !transcript.segments.isEmpty {
            result.append(NSAttributedString(
                string: "\nTranscript\n",
                attributes: [.font: h2Font, .foregroundColor: NSColor.labelColor, .paragraphStyle: h2Paragraph]
            ))

            for segment in transcript.segments {
                let segStr = NSMutableAttributedString()
                if options.includeTimestamps {
                    segStr.append(NSAttributedString(
                        string: "[\(AudioTime.format(segment.startTime))] ",
                        attributes: [.font: monoFont, .foregroundColor: NSColor.secondaryLabelColor]
                    ))
                }
                if options.includeSpeakers, let speaker = segment.speaker, !speaker.isEmpty {
                    segStr.append(NSAttributedString(
                        string: "\(speaker): ",
                        attributes: [.font: bodyBoldFont, .foregroundColor: NSColor.labelColor]
                    ))
                }
                segStr.append(NSAttributedString(
                    string: "\(segment.text)\n",
                    attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: bodyParagraph]
                ))
                result.append(segStr)
            }
        }

        // Chat
        if options.includeChat && !content.chat.isEmpty {
            result.append(NSAttributedString(
                string: "\nChat History\n",
                attributes: [.font: h2Font, .foregroundColor: NSColor.labelColor, .paragraphStyle: h2Paragraph]
            ))

            for msg in content.chat {
                result.append(NSAttributedString(
                    string: "\(msg.role)\n",
                    attributes: [.font: h3Font, .foregroundColor: NSColor.labelColor, .paragraphStyle: h3Paragraph]
                ))
                result.append(NSAttributedString(
                    string: "\(msg.text)\n",
                    attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: bodyParagraph]
                ))
                if !msg.sourceLabels.isEmpty {
                    result.append(NSAttributedString(string: "Sources: " + msg.sourceLabels.joined(separator: "; ") + "\n",
                        attributes: [.font: bodyFont, .paragraphStyle: bodyParagraph]))
                }
                if options.includeTimestamps && !msg.timestamps.isEmpty {
                    let tags = msg.timestamps.map { "[\(AudioTime.format($0))]" }.joined(separator: " ")
                    result.append(NSAttributedString(
                        string: "Sources: \(tags)\n",
                        attributes: [.font: monoFont, .foregroundColor: NSColor.secondaryLabelColor]
                    ))
                }
            }
        }

        return result
    }

    private func renderPDF(from attrString: NSAttributedString, title: String, cancellationCheck: () throws -> Void = {}) throws -> Data {
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else {
            return Data()
        }

        // A4 page size
        let pageWidth: CGFloat = 595.28
        let pageHeight: CGFloat = 841.89
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        let margin: CGFloat = 54
        let headerHeight: CGFloat = 32
        let footerHeight: CGFloat = 32

        let textRect = CGRect(
            x: margin,
            y: margin + footerHeight,
            width: pageWidth - (2 * margin),
            height: pageHeight - (2 * margin) - headerHeight - footerHeight
        )

        let framesetter = CTFramesetterCreateWithAttributedString(attrString as CFAttributedString)

        // Pass 1: Count total pages
        var totalPages = 0
        var testRange = CFRange(location: 0, length: 0)
        let totalLength = attrString.length

        while testRange.location < totalLength {
            try cancellationCheck()
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, testRange, path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }
            testRange.location += visible.length
            totalPages += 1
        }
        totalPages = max(totalPages, 1)

        // Pass 2: Draw pages
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }

        var closed = false
        defer { if !closed { context.closePDF() } }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }

        var currentRange = CFRange(location: 0, length: 0)
        var pageNumber = 1

        let headerFont = NSFont.systemFont(ofSize: 8.5, weight: .regular)
        let footerFont = NSFont.systemFont(ofSize: 8.5, weight: .regular)
        let dividerColor = NSColor.separatorColor.cgColor

        while currentRange.location < totalLength {
            try cancellationCheck()
            context.beginPDFPage(nil)

            // Draw Header
            if totalPages > 1 {
                let headerText = title as NSString
                let headerAttrs: [NSAttributedString.Key: Any] = [
                    .font: headerFont,
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
                let headerSize = headerText.size(withAttributes: headerAttrs)
                let headerY = pageHeight - margin - 14

                let headerRect = CGRect(x: margin, y: headerY, width: pageWidth - 2 * margin, height: headerSize.height)
                headerText.draw(in: headerRect, withAttributes: headerAttrs)

                // Divider line below header
                context.setStrokeColor(dividerColor)
                context.setLineWidth(0.5)
                context.move(to: CGPoint(x: margin, y: pageHeight - margin - 20))
                context.addLine(to: CGPoint(x: pageWidth - margin, y: pageHeight - margin - 20))
                context.strokePath()
            }

            // Draw content text
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, currentRange, path, nil)
            CTFrameDraw(frame, context)

            // Draw Footer
            let footerY: CGFloat = margin - 10
            context.setStrokeColor(dividerColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: margin, y: margin + footerHeight - 10))
            context.addLine(to: CGPoint(x: pageWidth - margin, y: margin + footerHeight - 10))
            context.strokePath()

            let footerPageText = "Page \(pageNumber) of \(totalPages)" as NSString
            let footerAttrs: [NSAttributedString.Key: Any] = [
                .font: footerFont,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let pageTextSize = footerPageText.size(withAttributes: footerAttrs)
            let pageRect = CGRect(
                x: pageWidth - margin - pageTextSize.width,
                y: footerY,
                width: pageTextSize.width,
                height: pageTextSize.height
            )
            footerPageText.draw(in: pageRect, withAttributes: footerAttrs)

            let appName = "Generated by AudioNotes" as NSString
            let appRect = CGRect(x: margin, y: footerY, width: 200, height: pageTextSize.height)
            appName.draw(in: appRect, withAttributes: footerAttrs)

            context.endPDFPage()

            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }
            currentRange.location += visible.length
            pageNumber += 1
        }

        context.closePDF()
        closed = true
        return pdfData as Data
    }
}
#endif
