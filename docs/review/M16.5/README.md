# M16.5 screenshot review

Actual Simulator captures: **49 screenshots — 6 before, 43 after**. Baseline presentation is from `bb4508d`. Screens introduced in this milestone have no fabricated before image. All content is synthetic; connected account layouts use an in-memory `.invalid` email. These screenshots establish layout evidence, not interactive acceptance or live account verification.

| Requested surface | Before | After |
| --- | --- | --- |
| Library, empty projects | [Library](before/library.png) | [Empty projects](after/library-empty-projects.png) |
| Library, several projects | — | [Projects](after/library-projects.png) |
| New Project | — | [Creation sheet](after/new-project.png) |
| Move to Project | — | [Picker](after/move-to-project.png) |
| Project detail | — | [Project](after/project-detail.png) |
| Recording detail | [Original transcript screen](before/transcript.png) | [Recording](after/recording-detail.png) |
| Transcript | [Transcript](before/transcript.png) | [Transcript](after/transcript.png) |
| Transcription empty state | [Original configuration](before/transcription-configuration.png) | [Create Transcript](after/transcription-empty.png) |
| Transcription configuration | [Configuration](before/transcription-configuration.png) | [Settings sheet](after/transcription-configuration.png) |
| Summary | [Summary](before/summary.png) | [Summary](after/summary.png), [empty state](after/summary-empty.png) |
| Chat | [Chat](before/chat.png) | [Chat](after/chat.png) |
| Settings root | [Settings](before/settings.png) | [Root](after/settings-root.png) |
| ChatGPT account | [Original combined Settings](before/settings.png) | [Account](after/chatgpt-account.png) |
| Gemini account | [Original combined Settings](before/settings.png) | [Account](after/gemini-account.png) |
| AI Defaults | [Original combined Settings](before/settings.png) | [Defaults](after/ai-defaults.png) |
| Light mode | — | [Library](after/library-light.png), [recording](after/recording-light.png), [Settings](after/settings-light.png) |
| Dark mode | — | [Library](after/library-dark.png), [recording](after/recording-dark.png), [Settings](after/settings-dark.png) |
| iPad library | — | [Light](after/ipad-library-light.png), [dark](after/ipad-library-dark.png) |
| iPad recording detail | — | [Light](after/ipad-recording-detail-light.png), [dark](after/ipad-recording-detail-dark.png) |

## Responsive review

- iPhone SE (3rd generation), iOS 26.5, 375-point width: [library with long project name](after/small-iphone-library.png), [long recording title](after/small-iphone-detail.png), [account](after/small-iphone-settings.png).
- Accessibility Extra Large on that small iPhone: [recording](after/small-iphone-accessibility-detail.png), [account](after/small-iphone-accessibility-settings.png), [long project](after/small-iphone-accessibility-project.png), [creation sheet](after/small-iphone-accessibility-new-project.png), [usage](after/small-iphone-accessibility-usage.png). Normal captures use the default Large text category.
- iPhone 17, iOS 27: primary comparison images above.
- iPhone 18 Pro Max, iOS 27: [library light](after/large-iphone-library-light.png), [dark](after/large-iphone-library-dark.png), [recording light](after/large-iphone-detail-light.png), [dark](after/large-iphone-detail-dark.png).
- iPad Pro 11-inch (M5), iOS 27: [Settings light](after/ipad-settings-light.png), [dark](after/ipad-settings-dark.png), [transcription configuration light](after/ipad-transcription-configuration-light.png), [dark](after/ipad-transcription-configuration-dark.png).
- Existing [Usage & Costs](after/usage-costs.png) remains a separate destination; its empty fixture does not manufacture costs.

## Reproduction and limits

DEBUG-only `--performance-fixtures --ios-audio-review --ios-ux-review` launches an in-memory library and temporary managed-file root with mock providers. `--ios-review-*` routes present the actual views; see `IOSRootView`, `IOSRecordingDetailShell`, and `IOSSettingsView`. The synthetic waveform is silence; fixture text and account identities contain no user content. Normal performance fixtures retain their original size.

Device interaction was disabled by the environment. Launch routes and `simctl` appearance/text-size changes produced these images. Swipe actions, typing/Return, keyboard avoidance, rotation, playback gestures and start/cancel by touch still require manual acceptance. Physical VoiceOver remains deferred.
