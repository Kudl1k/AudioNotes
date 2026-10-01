# Third-party licenses

The shipped local text `ThirdPartyLicenses.txt` includes full notices. Native Foundation, SwiftUI, SwiftData, PDFKit, Vision, AVFoundation, Core ML and CryptoKit are OS frameworks, not vendored packages.

| Component | Pinned version | License/source | Distribution |
| --- | --- | --- | --- |
| Sparkle | 2.10.0 | MIT plus bundled component notices, https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE | Embedded signed framework and upstream helpers. Retain the complete upstream LICENSE. |
| Argmax WhisperKit | 1.1.0 | MIT, https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.0/LICENSE | Linked native runtime; existing WhisperKit-LICENSE.txt and WhisperKit-NOTICES.txt retained. |
| swift-argument-parser | 1.8.2 | Apache 2.0 with runtime library exception, https://github.com/apple/swift-argument-parser/blob/1.8.2/LICENSE.txt | Transitive package; retain its notices even if no parser code reaches app binary. |
| OpenAI Whisper tiny/base/small and tokenizer | Pinned revisions in WhisperModels.json | MIT, https://github.com/openai/whisper/blob/main/LICENSE | User-requested downloads only; no weights in DMG. |
| Argmax Core ML conversions | 0f63a7800b00dd0226abd051b906c246e1907482 | https://huggingface.co/argmaxinc/whisperkit-coreml ; model card MIT label | User-requested downloads. Confirm pinned model-card and notice coverage before publication; legal acceptance remains open. |
| Ollama/model weights | User-installed | Each installed model's own license | Not bundled or automatically redistributed. Publisher cannot assert one license for all Ollama models. |
| Claude Code | User-installed | Vendor terms | Not bundled. Optional external workflow. |

No embedding model is distributed or recommended by this checkout. No third-party Markdown rendering package is used. Dependency/license/model redistribution acceptance is a release gate; do not claim it completed from a table alone.
