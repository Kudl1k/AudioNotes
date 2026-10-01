# M13 initial release audit

Audited 2026-10-01 before release changes. M13 is authorized; feature development is frozen. This checkout implements through M12.3 plus the M12.3.5 injection foundation. M12.4 and user-enabled semantic retrieval are absent. Prior native/live acceptance remains open. No release-readiness claim is made.

| Area | Initial state / decision |
| --- | --- |
| Identity | AudioNotes, `cz.kudladev.AudioNotes`, marketing 1.0, build 1, empty copyright. Retain identifier for existing preferences/Keychain/data; owner confirmation pending. |
| Target | Swift 6, macOS 15.0; current SDK Xcode 27. Older target desktop acceptance unverified. Ship candidate arm64 only because native Whisper is Apple Silicon gated. No Intel/Universal promise. |
| Configurations | Debug and optimized Release exist, Release dSYMs. DEBUG fixture/search tools guarded. Mock provider remains selectable in production: must restrict to development. |
| Security | Non-sandboxed desktop app, Hardened Runtime enabled. No explicit runtime-exception entitlements. Broad Xcode network capability toggles present. Import-only audio; no microphone needed. |
| Sandbox decision | Retain non-sandboxed direct distribution. Existing Claude subprocess, localhost OAuth callback, managed files, panel exports and Sparkle need full acceptance before any sandbox change. No JIT/unsigned-memory/library-validation exception for Release. |
| Info.plist | Private drag UTI declared; useful local-network description. ATS local networking plus specific `mac.lab` HTTP exception: development host should be removed. |
| Icon | Chosen AudioNotes.icon has waveform/sparkle SVG layers. Legacy empty AppIcon set unused. Inspect compiled fallback icns and installed presentation, especially macOS 15. |
| Dependencies | WhisperKit/argmax-oss-swift 1.1.0 pinned; transitive swift-argument-parser 1.8.2. No Sparkle. Avoid unrelated upgrades. |
| Signing | Team setting 4YU8YPQY6W; local identities are Apple Development only. No usable Developer ID identity found. Signing/notarization cannot be completed here yet. |
| Credentials | Provider Keychain service `cz.kudladev.AudioNotes.provider-credentials`, device-only/non-sync. ChatGPT/Google tokens use credential stores. Google OAuth source configuration is ignored developer configuration and excluded from all app targets; Gemini generation is unavailable. Never include credential values in diagnostics. |
| Providers | OpenAI API and ChatGPT path; Anthropic uses external Claude Code installation/account, not a bundled native API provider. Gemini resolver explicitly unavailable. Ollama requires separately installed/running server. Those optional paths must not block basic app launch/import. |
| Persistence | App opens `AppStorageLocations.applicationSupport()/default.store`; LibraryStorage tests use AudioNotes/Library.store. Production helper duplication should be consolidated without moving files. No VersionedSchema baseline. Failure currently preserves store but lacks Retry/reveal/diagnostics; Debug assertion interpolates raw error. |
| Managed files | AudioNotes/Recordings, Sources/<UUID>, Models/Whisper below selected Application Support root. Existing container support root retained if legacy data exists. Data stays outside app. Preferences in UserDefaults; secrets in Keychain. |
| Retrieval | Disposable in-memory lexical indexes, three scopes/48 MiB text hint. Semantic seam only; no downloaded embedding model or persisted vectors. |
| Whisper | Pinned HF file URLs/sizes/SHA256, local tokenizer override; install stage cleanup via defer, ready marker, inference lease, free-space check. Download session lacks explicit timeouts. Hard termination staging cleanup needs acceptance. Models not bundled. |
| Temporary files | OpenAI splitting and Claude request temporary directories have defer cleanup for normal success/error/cancellation. Crash remnants and deletion staging must not be blindly removed; staging currently lacks a durable restoration manifest. |
| Deletion | Project keep-recordings nullifies membership; explicit delete cascades history; recording/source file staging with rollback on save failure. Crash between stage and metadata commit requires durability hardening. Existing persistence/cascade tests available. |
| Logs | Signposts use static names. DebugLogService regex redaction is insufficient: OpenAI/ChatGPT clients log raw response bodies/refusals/generated content on error. Remove those payloads in all configurations; disallow free-form release debug logs. |
| Network | Cloud URLs HTTPS. Localhost Ollama uses no proxies/redirects and checks model metadata; Local Only gate wraps requests/hierarchy. Review external auth links and callback validation; existing tests. |
| UX | Native split view/settings/panels, library-owned jobs. No welcome/privacy/help/diagnostic export/recovery UI. About lacks build number. No updater/settings. |
| Release artifacts | No archive/export/notarization/DMG/appcast automation, no v1 persisted fixture. No production feed/public key configured. |
| QA | Existing mock/offline tests cover provider errors, Local Only, prompt boundaries, imports, citations, export, cancellation and migrations. Clean-machine/quarantine/update/signature-failure/VoiceOver/long-session testing remains mandatory. Component timings are not desktop acceptance. |

Repository scan: tracked files scanned for common API/private-key formats without printing values; sole hit is the deliberately synthetic `sk-` redaction fixture in ChatGPTAuthTests. No real credential discovered by that scan. This heuristic is not a complete history/secret audit; inspect history before publishing.

Remote analytics/crash reporting decision: none for v1. Use manually exported allowlisted local diagnostics. Do not include existing free-form debug logs in exports.

Production identity, copyright, hosting, Developer ID, notarization profile and Sparkle key are external configuration blockers. Manual acceptance is a release gate, not a substitute for automated checks.
