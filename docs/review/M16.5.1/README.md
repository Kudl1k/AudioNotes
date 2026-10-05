# M16.5.1 visual review

**34 raw screenshots + 4 before/after panels.** Actual iOS/iPadOS **26.5** Simulator captures of the uncommitted M16.5/M16.5.1 candidate. All recording text, conversations, audio, library entries and accounts are synthetic and offline. These are native SwiftUI screenshots; account connection and provider execution are not live acceptance. Existing M16.5 images were audited before editing.

## Core review set

| Surface | Capture |
| --- | --- |
| Recording transcript, Dark | [Dark](recording-transcript-dark.png) |
| Recording transcript, Light | [Light](recording-transcript-light.png) |
| Transcription empty state | [Create Transcript](transcription-empty.png) |
| Transcription settings | [Native Form sheet](transcription-settings.png) |
| Generated summary | [Summary](summary.png) |
| Recording Chat | [Populated conversation](recording-chat.png) |
| Library | [Projects and recordings](library.png) |
| Project detail | [Project](project-detail.png) |
| Settings root | [Settings](settings-root.png) |
| ChatGPT account | [ChatGPT](chatgpt-account.png) |
| Gemini account | [Google / Gemini](gemini-account.png) |
| Smallest review iPhone, 375-point width | [Long recording title](small-iphone-detail.png) |
| Large iPhone, 440-point width | [Dark](large-iphone-detail-dark.png), [Light](large-iphone-detail-light.png) |
| iPad recording detail | [Dark](ipad-detail-dark.png), [Light](ipad-detail-light.png) |
| iPad library | [Dark](ipad-library-dark.png), [Light](ipad-library-light.png) |

## Additional acceptance evidence

- Small iPhone: [Accessibility Extra Large detail](small-iphone-accessibility-detail.png), [compact empty state](small-iphone-empty.png), [Chat](small-iphone-chat.png), [Accessibility Extra Large account](small-iphone-accessibility-account.png).
- Final transcript: [Last segment](transcript-final-segment.png). DEBUG launch scrolls to the last lazy row after layout; production scroll behavior is unchanged.
- Accessibility: [Increased Contrast](recording-increased-contrast.png) uses the Simulator setting. [Opaque player fallback](recording-reduce-transparency.png) and [opaque composer fallback](chat-reduce-transparency.png) explicitly force the control modifier's solid fallback using a DEBUG launch argument. These two images do **not** verify the OS Reduce Transparency setting or system toolbar rendering.
- iPad: [Transcription sheet](ipad-transcription-settings.png), [Chat](ipad-chat.png).
- Sheets/empty states: [New Project](new-project.png), [Move to Project](move-to-project.png), [Create Summary](summary-empty.png).
- Scale fixtures: [6,000 transcript segments](long-transcript-6000.png), [250 chat messages](long-chat-250.png), [401 library recordings](large-library-401.png). Static rendering evidence only; no FPS, hitch-free gesture scrolling or stream/keyboard acceptance is claimed.
- Before/after panels: [Transcript](comparison-transcript.png), [Create Transcript](comparison-empty.png), [Summary](comparison-summary.png), [Project](comparison-project.png). Panels place existing M16.5 captures beside the new raw captures; the before set used iOS 27, so system rendering may differ. No source screenshot is altered.

## Reproduction

Build `AudioNotesiOS` Debug for Simulator. Run `python3 docs/review/M16.5.1/capture.py /path/to/AudioNotes.app --group standard` and repeat for `small`, `large`, `ipad`. Device UUIDs are environment-specific; the script lists them explicitly for repeatability. `--only <capture names>` recaptures corrections. It resets content size, contrast and status-bar override when complete.

Every launch includes `--performance-fixtures --ios-audio-review`. Ordinary review adds `--ios-ux-review`; the long-transcript route deliberately omits it to retain 6,000 segments. Additional chat/library fixtures are explicit DEBUG flags in the same in-memory store and separate temporary managed-file root. Providers remain fixed mocks. Connected identities use `.invalid` emails and disabled credential/connection actions. No private data, secrets or metered generation are involved.

Standard: iPhone 17. Small: existing iPhone SE (3rd generation) review Simulator. Large: iPhone 17 Pro Max. Tablet: iPad Pro 11-inch (M5). All use iOS/iPadOS 26.5. Ordinary images use the default Large content-size category. Small accessibility images use Accessibility Extra Large.

Device interaction access was disabled. Keyboard/Return, taps, dragging the seek slider, sheet resizing, rotation, scroll intent during streaming, gesture performance, physical VoiceOver and real Reduce Transparency acceptance remain pending. A screenshot is not a substitute for those checks.

The additional New Project image includes the Simulator keyboard onboarding panel, not app content. Cold-start captures default to eight seconds after fixture readiness and still require visual inspection; the final iPad sheet/Chat recapture used `--settle 12`.
