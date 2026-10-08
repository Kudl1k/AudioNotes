# M16.6 Project Sources and Chat review

Deterministic DEBUG-only Simulator captures use a synthetic in-memory project with
20 recordings/transcripts, 30 managed PDF/text/OCR sources, and a persisted
250-message Project Chat history. The iPad capture uses the same fixture generator
and final question/answer/citations in an eight-message layout window; iPhone captures
retain all 250 messages. No provider was called. The Sources fixtures include valid
local PDFs and images. Import progress uses static queue state through production row
presentation; it is not an import-throughput measurement.

## iPhone 17e · iOS 26.5

| Review state | Capture |
| --- | --- |
| Project recordings | [Dark](project-recordings-dark.png) |
| Empty project sources | [Light](sources-empty-light.png) |
| Populated source list | [Light](sources-populated-light.png) |
| Mixed import progress and failure | [Light](project-import-progress-light.png) |
| Source processing | [Dark](source-processing-dark.png) |
| Source processing failure with mapped reason | [Light](source-failure-light.png) |
| PDF opened on page 2 | [Light](pdf-viewer-light.png) |
| Image source viewer | [Dark](image-viewer-dark.png) |
| Markdown source viewer | [Light](markdown-viewer-light.png) |
| Project Chat empty state | [Dark](project-chat-empty-dark.png) |
| Recording citation | [Light](project-chat-recording-citation-light.png) |
| PDF citation | [Light](project-chat-pdf-citation-light.png) |
| Mixed citations and 250-message history | [Dark](project-chat-mixed-citations-dark.png) |
| Accessibility-size chat | [Large Dynamic Type](project-chat-accessibility.png) |

## Additional device sizes

| Device | Capture set |
| --- | --- |
| iPhone 17 Pro Max · iOS 26.5 | [`large-iphone/`](large-iphone/), including 250-message history and populated Sources |
| iPad Pro 11-inch (M5) · iOS 26.5 | [`ipad/`](ipad/), including populated mixed-citation chat |

## Reproduction

Build AudioNotesiOS Debug for Simulator, install it, then run:

```sh
python3 docs/review/M16.6/capture.py <simulator-udid> --group iphone
python3 docs/review/M16.6/capture.py <ipad-udid> --group ipad --output docs/review/M16.6/ipad
```

The capture uses `--performance-fixtures --ios-project-knowledge-review` and
additional state arguments. `IOSProjectKnowledgeFixtures` and static progress queue
state are compiled only in DEBUG. iPad Project Chat adds
`--ios-project-chat-compact-review` so it presents the same final conversation in a
layout-sized window. Screenshots verify rendered surfaces; they do not verify taps,
Files picker interaction, scrolling gestures, keyboard behavior, physical VoiceOver,
or runtime import throughput. The 250-message iPad scroll presentation is not
classified from static evidence.

The refreshed captures replace the previous empty iPad chat and missing progress
rows. Chat loads persisted fixture models through `ProjectChatViewModel.attach` and
shared message/citation presentation. Import rows come from the production queue and
Sources view; failure text uses the shared source error mapping. See [the
implementation report](../../IOS_PROJECT_SOURCES_AND_CHAT.md#validation-and-remaining-acceptance).

All source names, transcripts, excerpts, and account state are synthetic. No user
library, provider credentials, or metered provider calls are used.
