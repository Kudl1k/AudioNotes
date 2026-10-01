import Foundation

enum SummaryPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case general
    case meeting
    case lecture
    case interview
    case podcast
    case brainstorm
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .meeting: "Meeting"
        case .lecture: "Lecture"
        case .interview: "Interview"
        case .podcast: "Podcast"
        case .brainstorm: "Brainstorm"
        case .custom: "Custom"
        }
    }

    var displayName: String { title }

    var systemInstructions: String {
        switch self {
        case .general:
            "Provide a concise executive overview, the most critical key points, and notable details in additional sections."
        case .meeting:
            "Provide an executive overview, key discussion points, explicit decisions agreed upon, concrete action items with assignees/due dates if stated, and unresolved open questions."
        case .lecture:
            "Provide an educational overview, main concepts, key definitions, illustrative examples, study notes, and review questions in additional sections."
        case .interview:
            "Provide an overview of the conversation, major topics explored, key answers given by the interviewee, notable direct quotes, and follow-up topics."
        case .podcast:
            "Provide an entertaining yet insightful overview, topics discussed, central arguments and narratives, notable insights, and memorable quotes."
        case .brainstorm:
            "Provide an overview of the brainstorming session, ideas generated, emergent themes, promising directions, unresolved questions, and potential next steps."
        case .custom:
            "Provide a customized summary tailored to the user's specific workflow requirements while maintaining grounding and factual accuracy."
        }
    }

    var iconName: String {
        switch self {
        case .general: "doc.text"
        case .meeting: "person.3"
        case .lecture: "graduationcap"
        case .interview: "mic"
        case .podcast: "headphones"
        case .brainstorm: "lightbulb"
        case .custom: "slider.horizontal.3"
        }
    }
}
