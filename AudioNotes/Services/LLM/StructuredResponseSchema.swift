import Foundation

enum StructuredResponseSchema {
    static func summarySchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "title": [
                    "type": "string",
                    "description": "Concise, descriptive title reflecting the main subject of this summary, in the same language as the summary."
                ],
                "referenceChunkIDs": ["type": "array", "items": ["type": "string"]],
                "overview": [
                    "type": "string",
                    "description": "High-density executive summary of the transcript."
                ],
                "keyPoints": [
                    "type": "array",
                    "description": "Crucial points discussed.",
                    "items": ["type": "string"]
                ],
                "decisions": [
                    "type": "array",
                    "description": "Explicit decisions agreed upon.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"],
                            "timestampSeconds": [
                                "anyOf": [["type": "number"], ["type": "null"]]
                            ]
                        ],
                        "required": ["text", "timestampSeconds"],
                        "additionalProperties": false
                    ]
                ],
                "actionItems": [
                    "type": "array",
                    "description": "Action items or next steps assigned to individuals or teams.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"],
                            "assignee": [
                                "anyOf": [["type": "string"], ["type": "null"]]
                            ],
                            "dueDate": [
                                "anyOf": [["type": "string"], ["type": "null"]]
                            ],
                            "timestampSeconds": [
                                "anyOf": [["type": "number"], ["type": "null"]]
                            ]
                        ],
                        "required": ["text", "assignee", "dueDate", "timestampSeconds"],
                        "additionalProperties": false
                    ]
                ],
                "openQuestions": [
                    "type": "array",
                    "description": "Unresolved questions, uncertainties, or pending matters.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"],
                            "timestampSeconds": [
                                "anyOf": [["type": "number"], ["type": "null"]]
                            ]
                        ],
                        "required": ["text", "timestampSeconds"],
                        "additionalProperties": false
                    ]
                ],
                "importantQuotes": [
                    "type": "array",
                    "description": "Notable direct quotes from speakers.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"],
                            "speaker": [
                                "anyOf": [["type": "string"], ["type": "null"]]
                            ],
                            "timestampSeconds": [
                                "anyOf": [["type": "number"], ["type": "null"]]
                            ]
                        ],
                        "required": ["text", "speaker", "timestampSeconds"],
                        "additionalProperties": false
                    ]
                ],
                "additionalSections": [
                    "type": "array",
                    "description": "Preset-specific sections such as Study Notes, Main Concepts, Follow-up Topics, or Themes.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "items": [
                                "type": "array",
                                "items": ["type": "string"]
                            ]
                        ],
                        "required": ["title", "items"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": [
                "title",
                "referenceChunkIDs",
                "overview",
                "keyPoints",
                "decisions",
                "actionItems",
                "openQuestions",
                "importantQuotes",
                "additionalSections"
            ],
            "additionalProperties": false
        ]
    }

    static func chatSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "answer": [
                    "type": "string",
                    "description": "Clean Markdown answer addressing the user's question. No segment IDs, UUIDs, citation tokens, or timestamps in the answer body."
                ],
                "referenceSegmentIDs": [
                    "type": "array",
                    "description": "IDs of segments cited as supporting evidence.",
                    "items": ["type": "string"]
                ]
            ],
            "required": ["answer", "referenceSegmentIDs"],
            "additionalProperties": false
        ]
    }

}
