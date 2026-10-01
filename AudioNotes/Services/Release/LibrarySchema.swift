import SwiftData

/// v1 schema baseline. Never change its model structure after publishing v1.
/// Before v2, freeze these model declarations in a nested v1 namespace and add
/// v2 declarations + a tested migration stage. See docs/RELEASING.md.
enum LibrarySchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [Project.self, Recording.self, RecordingSource.self, SourceTextUnit.self,
         Transcript.self, TranscriptSegment.self, Summary.self, ChatSession.self,
         ChatMessage.self, AIPreset.self, GenerationRecord.self]
    }
}

enum LibraryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LibrarySchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
