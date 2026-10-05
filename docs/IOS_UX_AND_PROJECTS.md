# M16.5 — Native iOS UX and project organization

Status: committed in `a73f72f`; interactive Simulator acceptance remains open.
Baseline: `bb4508deace2705e9accf42c40f1c44682a9a5c5`. The initial working tree and `git diff --check` were clean. Baseline results supplied with the milestone and recorded in `IOS_CLOUD_AI.md`: macOS 443 passed / 6 skipped / 0 failed; iPhone 38 passed; iPad 38 passed.

## Before-state problems

The library had inert empty-project text and an import-only plus button. Projects had no mobile create/rename/delete/move affordances. Opening a recording through a project constructed fresh default services. Recording detail repeated the title and filename above a fixed-height header and large player. Transcription and summary empty states exposed configuration before the primary action. Settings combined account identities, billing explanations, API credentials and generation options into one long form.

## Information architecture and project workflow

On iPhone, a `NavigationStack` presents Projects followed by All Recordings. Projects remain optional. On iPad, `NavigationSplitView` retains library/project destinations in the sidebar, with a detail navigation stack. Recording rows use the user-facing title (two lines, tail truncation), duration, and locale-aware date/time with readable secondary metadata.

The plus menu exposes Import Audio and New Project, the two implemented mobile actions. Microphone recording and non-audio file importing are not added. New Project and Rename Project use a compact native Form sheet, focus the name field, reject whitespace and accept Return. Creating a project opens it. Context menus and trailing swipe actions offer Rename/Delete; project detail also has an overflow menu.

Project mutation uses `LibraryViewModel` and `SwiftDataProjectRepository`, not direct SwiftData writes in views. Deletion confirmation retains the existing domain choices: Delete Project, Keep Recordings; or Delete Project and Recordings. Project sources/chat are removed in both cases. Shared cancellation/file-staging/deletion semantics remain authoritative. Moving a recording changes membership only; no managed file copy or history recreation occurs. Leading swipe, recording context menus and detail overflow open a project picker with Library (no membership) and existing projects. Selection moves and dismisses. Remove from Project is available for members.

Project detail has native Recordings and Sources destinations with counts, optional description and creation date. Its recordings open the configured, library-owned AI models. Project Chat and project document import remain Mac-only; the screen states this limitation. No mobile Project Chat, OCR/import workflow or later milestone is introduced.

## Recording detail and player

The navigation bar is the single recording title. There is no duplicate giant content title or filesystem filename header. Duration/date precede Transcript/Summary/Chat. Accessibility text sizes replace the segmented control with a native menu picker. Text content has a 760-point maximum readable width on iPad.

Rename, Move, Remove, Delete, transcription settings, regeneration and recording usage live in the overflow menu. Delete uses a destructive confirmation and shared repository logic. Existing iOS export is not implemented in this pass; no unsupported export menu item is exposed.

A compact persistent player sits in `safeAreaInset(edge: .bottom)` for Transcript/Summary. Chat keeps its playback control above the message list, leaving the composer above the keyboard. Play/pause, current position, duration and seeking remain supported. Scrubbing holds its preview value and commits the final seek. At accessibility sizes the slider gets a separate row. Load/session errors remain visible. Playback observation stays in the player leaf, with no new parent timers.

Transcript segments use speaker/timestamp followed by text without cards. Native timestamp buttons and existing accessibility activation still seek audio. Search, cancellation/supersession guards and off-actor filtering remain shared. Summary overview Markdown parses off actor with cancellation rejection; structured decisions/action/quote timestamp buttons remain intact. Summary history and regeneration remain available.

The library now supplies the cached `RecordingViewModel`, `SummaryViewModel`, and `ChatViewModel` in both root and project navigation. This retains operations/drafts/overrides while navigating rather than recreating them with each destination. Shared chat rows, composer, scroll intent, Markdown, progress, citations and stream batching remain in use. A small composer options menu opens defaults and confirms Clear Chat.

## Transcription and summary configuration

The primary empty state is Create Transcript, its explanation and Transcribe. Secondary text identifies the resolved provider/model and whether it uses defaults or custom settings. Change opens a native Transcription Settings sheet. It checks credentials/account availability once on presentation and offers configured transcription-capable providers only. ChatGPT Plan is never a transcription provider. Mock appears only in development when explicitly in use.

The sheet exposes provider/model, OpenAI language, and Reset to Defaults. Language is a transient recording override routed through the existing resolver; it does not change the global default. Gemini retains automatic language and provider-supplied speaker labels; no fictional language/diarization capability or switch is added. Model choices come from existing provider descriptors. Changing provider clears a stale model. Reset clears provider, model and language overrides so subsequent resolution follows current defaults. Overrides survive navigation in the library model, but are not new persisted fields.

Summary empty state similarly leads with Create Summary and Generate Summary. Change opens a native Form for source selection, provider, preset, length and custom instructions. Advanced links to existing preset editing, retaining max-token/temperature/top-p/reasoning options and existing capability filtering. Custom preset save/manage and non-destructive regeneration/history remain available. There is no new transcription preset persistence model; none is invented.

## Settings

Root Form:

- Accounts: ChatGPT; Google / Gemini, with icon + textual connection state.
- AI: Defaults; Presets.
- Storage & Data: Usage & Costs.
- About: About AudioNotes.

ChatGPT separates account identity/plan authorization/Manage Plan Usage from a pushed OpenAI API-key destination. Key entry/removal continues through the existing Keychain settings model. Google/Gemini puts its Cloud project billing and consumer-subscription distinction on the account page. Both disconnect actions require destructive confirmation and show failures instead of silently swallowing them. Connection status does not depend on green text.

AI Defaults has three independent destinations: Transcription, Summary and Chat. Available provider choices require configuration and mobile capability; OpenAI API and ChatGPT Plan access remain distinguishable for generation. Models and language retain existing non-secret preference storage. Presets reuse the shared editor/operations with iOS menus and no desktop minimum sheet width.

Local AI and Storage management are omitted from the root because neither has an implemented iOS destination. Local Whisper/Ollama remain deferred to M16.7. Usage & Costs presents the existing dashboard/repository; no invented analytics is added. Its desktop minimum width is excluded on iOS, and its header/time-range control adapts at accessibility sizes. Unknown/unavailable costs remain unavailable and plan usage remains separate from metered API calculations.

## Accessibility and adaptive decisions

System typography, semantic foreground/background/materials, native navigation/Form/List/Menu/sheets and destructive roles are used throughout. New identifiers cover library add, project name/save/actions, move picker, recording content, transcription configure/provider/model/language/reset, settings account/default/usage destinations, disconnect actions and chat options. Play/pause/seek and selected project have labels/values. Status includes text and a checkmark, not color alone.

Small iPhone and long-title/name/account-email review uses real Simulator rendering, not geometry assertions. The transcript heading adapts horizontally/vertically; provider/account information wraps; content remains scrollable. Large Dynamic Type gets a menu for content navigation and a two-row player. iPad keeps sidebar navigation and bounded reading widths instead of stretching phone text across the screen. Settings remains a native navigation sheet, not an added custom split interface.

Physical VoiceOver remains deferred. Interactive keyboard, rotation, gestures and reachability must still be verified manually; screenshots cannot certify them.

## Screenshots and reproducibility

See [review inventory](review/M16.5/README.md). Baseline screenshots use the exact `bb4508d` presentation in a temporary detached worktree, with DEBUG-only launch navigation and a reduced synthetic fixture. No baseline presentation is redesigned for screenshots. After screenshots use the actual redesigned views. Features absent before (New Project/Move sheets) have no fabricated before image.

Review launch requires `--performance-fixtures --ios-audio-review --ios-ux-review`. Additional `--ios-review-*` arguments select actual destinations. Review storage is in-memory with a separate temporary managed-file root. Review preferences use a separate suite. Inference is forced through fixed mock resolvers; account restoration/discovery is skipped. Synthetic connected-account presentation, when requested, is in-memory only, uses an `.invalid` email and disables credential/connection/disconnection actions. No credentials are seeded and no paid provider is used.

Normal 6,000-segment performance fixtures remain unchanged; the UX flag reduces the screenshot fixture to 24 segments. Screenshot layout review is not a scrolling/performance benchmark.

## Validation and integrity

Validation on October 5, 2026:

| Check | Result |
| --- | --- |
| Full macOS tests | 454 passed, 6 skipped, 0 failed (460 total) |
| Full iPhone Simulator tests | 49 passed, 0 failed |
| Full iPad Simulator tests | 49 passed, 0 failed |
| AudioNotes macOS Release | Build succeeded |
| AudioNotesiOS Debug Simulator | Build succeeded through the full test builds |
| AudioNotesiOS Release Simulator | Build succeeded |
| New Swift compiler warnings | None |
| Screenshots | 49: 6 before, 43 after |
| `git diff --check` | Clean |

The 11 added behavior tests cover project creation/blank rejection/rename, deletion confirmation and keep-recordings deletion, move/remove with history/files retained, transcription credential/capability filtering, default/override/reset resolution, and account-versus-plan authorization state. Existing tests cover the remaining shared deletion and provider behavior. The six macOS skips remain opt-in native/live/performance checks. Existing AppIntents metadata extraction warnings are build-tool diagnostics, not new Swift warnings.

No paid/live provider call was used for UX validation. Launch-route screenshots cover actual rendered surfaces on three iPhone widths, iPad, Light/Dark and Accessibility Extra Large. They do not replace the manual interaction matrix below.

The SwiftData models, `LibrarySchemaV1`, `LibraryMigrationPlan`, signing, bundle identities, OAuth registrations/configuration, Sparkle and release configuration compare byte-for-byte to `bb4508d`. Xcode automatically rewrites `objectVersion` to 110 during builds; the final working project is restored to 77 without changing any other project configuration.

## Manual Simulator acceptance still required

| Platform | Pending interactive checks |
| --- | --- |
| iPhone | Create/rename/delete project; move recording in/back; import/open recording; switch Transcript/Summary/Chat; choose provider/model and reset; start/cancel mock transcription; Settings/account/default navigation; keyboard/Return; rotation; Light/Dark interactions |
| iPad | Sidebar and project navigation; recording detail; Settings; provider configuration; Light/Dark interactions |

Automated domain tests, successful builds and captured layouts are complete. This matrix is explicitly **pending**, because device interaction access is disabled. Physical VoiceOver remains deferred as requested.

## Remaining acceptance and UX debt

- Device interaction tools returned “Agent device access is turned off for this environment.” Touch/swipe/context-menu workflows, Return/focus, keyboard avoidance, rotation, start/cancel by touch, and provider sheet selection need manual Simulator acceptance. Unit tests and launch-route screenshots are separate evidence.
- Live account connection/disconnection and provider requests were not performed. Synthetic account screenshots are layout evidence only.
- Project Chat/document import, local AI, storage management and mobile export remain unavailable in this pass; the UI exposes only supported destinations.
- Existing preset management/editor and Usage dashboard still share much of their cross-platform presentation. No new preset model or analytics was introduced.
- Navigation-title truncation is intentional for long recording names; full titles remain in the library and Rename field. No scroll-collapsing custom title system is introduced.

M16.5 was subsequently committed as `a73f72f`; see the repository-state reconciliation below. The interactive acceptance listed here remains deferred because device access is unavailable.

## M16.5.1 — iOS 26 visual refinement

### Screenshot audit before changes

Reviewed all 49 existing M16.5 images (6 baseline, 43 candidate) before editing. Recording detail already has a single inline native title; adding a second hero title would reintroduce duplication. Metadata/selector are close, but the outer 16-point margin compounds transcript's 16-point margin and summary's 20-point margin. Transcript's 44-point timestamp heading plus 6-point internal spacing plus 16-point intersegment spacing makes short segments unnecessarily tall. Summary's vertical header places preset, date, provider, spacer and each action on separate lines before the actual notes. Empty states spread provider/default status and Change across several rows after the action. The player has both an attached full-width material strip and separate inset padding. Chat likewise attaches playback to a material strip and separates provider/composer with a divider. These are the primary refinement targets.

Library, Settings root, account pages, project detail and provider sheets already use native List/Form rows. Preserve that hierarchy. Account labels can become LabeledContent; project creation metadata and unavailable Project Chat explanation can become footers rather than extra content cards. Library toolbar already receives the platform treatment: no added backgrounds. The provider sheet's duplicate configuration preamble can become a reset footer. Existing small-screen accessibility screenshots show why the menu selector and two-row player must remain; the keyboard tutorial in the old New Project screenshot is Simulator presentation, not app content.

Glass is appropriate for the floating player/composer, compact provider Change control and primary actions. Transcript segments/timestamps, Markdown, recording/source rows and Settings content remain flat. No per-row glass.

### Liquid Glass and availability

`IOSControlSurface` uses public `glassEffect(.regular, in:)` on iOS/iPadOS 26+. `IOSGlassControls` groups adjacent surfaces through `GlassEffectContainer(spacing: 8)`. `IOSPrimaryAction` uses `.buttonStyle(.glassProminent)` for Transcribe and Generate Summary. Navigation/toolbars, sheets and the segmented Picker retain native system styling without extra glass backgrounds. Strategy follows Apple's [custom glass guidance](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views) and [adoption guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass).

Only the player, composer, compact transcription provider/Change control and primary generation buttons request custom glass. Long transcript rows, timestamps, Markdown, chat messages, summary items, project/source/recording rows and Settings rows do not. Timestamp capsules use a semantic solid content background, not glass. No shaders, recreated effects, blur, custom gradient or translucent color stacks. The floating player has one surface, not a material strip behind another background.

Deployment remains **iOS 18.0**. Availability branches wrap rendering modifiers rather than duplicate view hierarchies. Earlier systems use one native regular-material control surface and bordered prominent buttons. Reduce Transparency and increased contrast select solid `secondarySystemBackground` controls with a semantic primary outline and standard prominent actions. System navigation/Picker rendering remains Apple's responsibility. No macOS glass changes.

### Detail hierarchy and padding inventory

A single system inline navigation title remains the recording heading. SwiftUI's native large-title collapse is useful only when the owning screen has one scroll container; this detail owns separately scrolling Transcript/Summary/Chat panes. Introducing a second content title or an offset-based replacement would create duplicate names and fragile synchronization. Keep the compact title permanently visible, naturally truncating long names. The overflow menu now includes the complete recording title; Rename also exposes it. No title hero or large content header.

The shell owns the 16-point horizontal reading margin. Its metadata/selector are followed immediately by each content pane. Native segmented Picker remains for ordinary text sizes; the existing menu Picker remains at accessibility sizes. Search, cancellation guards, off-actor Markdown/search, library-owned models, stream batching and navigation authority are unchanged.

The following values are **layout inputs in points**, not pixel-position tests. Native text/control metrics and Dynamic Type still determine final geometry.

| Relationship | M16.5 before | M16.5.1 after | Reason |
| --- | --- | --- | --- |
| Navigation → title | System inline title | System inline title | No duplicate content title |
| Navigation → metadata | 12 shell top | 4 shell top | Remove unnecessary top gap |
| Title → metadata | System nav bar + 12 | System nav bar + 4 | Same single-title hierarchy |
| Metadata → selector | 12 stack | 8 stack | Compact header grouping |
| Selector → content pane | 12 stack | 8 stack | Content begins earlier |
| Selector → transcript search | 12 + 8 = 20 | 8 + 4 = 12 | Remove compounded top space |
| Search → transcript scroll content | 16 inner padding | 8 inner vertical padding | Align search and text |
| Transcript horizontal margin | 16 shell + 16 child = 32 | 16 shell + 0 child = 16 | One reading margin |
| Segment heading → text | 6 | 4 | Micro spacing |
| Segment → next segment | 16 | 12 | Clear but denser blocks |
| Timestamp touch height | 44 | 44 | Retain reachable activation; visible capsule is smaller |
| Selector → summary header | 12 + 20 = 32 | 8 + 8 = 16 | Notes begin earlier |
| Summary horizontal margin | 16 + 20 = 36 | 16 + 0 = 16 | Same content edge as transcript |
| Summary sections | 20 | 12 | Typography carries hierarchy |
| Summary item decoration | 10–12 all-side padding + card | 4 vertical + flat content | Remove unnecessary cards |
| Empty-state components | Native ContentUnavailableView intrinsic spacing + separate default/provider/Change/action rows | 12 group spacing, 4 title/description, 8 provider-control internal vertical | Coherent action group; no default-status row |
| Content → bottom player | Implicit system safe-area inset spacing; attached material strip | Explicit 8 inset spacing; floating surface | Reserve actual control geometry without manual scroll padding |
| Player vertical padding | 6 outside bar, plus full-width background | 4 inside surface; 6 bottom placement | 44-point controls + 8 = 52-point ordinary surface |
| Chat provider/composer | Divider + provider row + composer with separate field background | Options menu inside single composer surface | One compact input row |

Player keeps play/pause, current time, duration and seek binding. Ordinary height is 52 points (44-point control plus two 4-point vertical insets); error content and accessibility text sizes expand naturally. Accessibility layout retains a separate slider row. Bottom `safeAreaInset(spacing: 8)` reserves the actual player height and adapts to safe areas. There is no extra transcript/summary bottom spacer. Chat playback stays above the messages, with the composer now in its own bottom safe-area inset; the keyboard is not ignored. Final-content screenshot is an explicit DEBUG scroll route, not a scrolling benchmark.

Summary version/preset/date/cost controls are compact. History, Make Current and Regenerate remain in Versions. iOS regeneration settings now use native Form sections; structured notes and Markdown remain the main content. macOS summary padding/cards retain the previous presentation.

### Transcription, Settings and sheets

The transcription prompt uses a compact waveform/title/description group, resolved provider/model plus Change, then Transcribe and the existing estimate. No primary-flow Provider/default/preset terminology. Defaults/overrides/reset and credential/capability filtering remain authoritative. The settings sheet removes its duplicate provider preamble; Provider/Model/Options and Reset remain native Form sections. A footer states defaults versus custom overrides. Do not invent a preset, advanced panel or speaker-detection toggle absent from the functional model.

Settings preserves M16.5 Accounts/AI/Usage/About destinations. Account state, email, plan authorization, API-key state and billing use native LabeledContent; long emails wrap according to native Form behavior. Settings, library and account rows receive no custom glass or card styling. Project detail retains its native inline title and destination rows; creation metadata and Mac-only Chat explanation are one footer instead of two additional groups.

Sheet audit: New/Rename Project allows 240-point/medium/large detents so the name/keyboard task can grow. Move and transcription use medium/large with visible drag indicators. Summary configuration/regeneration use medium/large with native Forms. Settings/Usage and substantial preset editing/management retain system large presentations because they contain multiple pushed destinations or editing content. No tiny forced keyboard sheet. Existing summary-history list remains system-presented; no custom material background is added to any sheet.

The remaining detail values were also audited: progress uses a scrollable operation view with 16-point vertical placement instead of a 20-point stack with two spacers and nested all-side padding; empty prompts use 20-point outer vertical placement to distinguish the action group from the selector; provider labels use 4-point internal text spacing; chat uses a zero-spacing content column with a 4-point playback/message separation and the same 8-point composer inset; player error/accessibility rows use 4-point spacing. No unconditional 24–40-point vertical detail margin remains.

A second screenshot pass caught iOS 26 expanding status rows when a `Label` was nested inside the value of `LabeledContent`. Replacing that nested label with textual Connected/Not Connected values keeps native compact rows and a non-color status. This was corrected before the final review set. Assistant chat answers are now flat on iOS; user questions retain a modest bubble for role separation. The message list no longer adds a second horizontal margin. Copy/regenerate actions, Markdown, trusted citations and scrolling intent remain unchanged. Desktop chat cards retain their prior geometry.

### Visual review questions and findings

For each major screen, the review explicitly asked: **Is there unnecessary empty space? Is content visible early enough? Is hierarchy obvious? Are controls visually heavier than content? Is glass used for interaction rather than decoration? Are there too many rounded rectangles? Is anything manually styled that the system should style? Does this look intentional on iOS 26?** Findings below refer to captured layouts, not gesture acceptance.

| Screen | Review findings |
| --- | --- |
| Recording / Transcript | One compact title; metadata and native selector precede search/text quickly. Single reading margin and trailing timestamp capsules. Content stays flat. One custom player surface. Scrolling beneath floating controls is intentional; the last segment can sit fully above them. |
| Transcription empty | Icon/title/description/provider/action form one group. Remaining blank space represents absent content, not multiplied component margins. Glass belongs to Change and Transcribe. No extra default-status card. Fits the small iPhone at ordinary text size. |
| Transcription settings | Native Form sections and a system sheet; duplicate configuration card removed. Mock screenshots have no model/options rows because that provider exposes none. Real credential-dependent provider/model selection remains a manual check. |
| Summary | Preset and Versions share a short header; date/cost is secondary. Notes start much earlier. Action/decision/quote cards removed on iOS. Markdown code blocks retain their semantic renderer; no glass paragraphs. |
| Recording Chat | Flat assistant Markdown, a modest user question bubble, existing trusted source chips, one floating composer and one player. Options sit inside the composer; no provider row/divider/second field background. History can scroll without glass on its rows. |
| Library | Native content rows and system plus/Settings toolbar. Existing M16.5 hierarchy preserved. No glass tiles, redundant toolbar fills or invented workflow. |
| Project | Single inline title, native destination rows, creation/unavailable-Chat information in a footer. Large remaining space is the small amount of implemented content, not a hero header. |
| Settings root | Native Accounts/AI/Usage/About sections; status is a compact textual value. No manual cards or materials. Expanded-row rendering defect caught and corrected. |
| Account detail | Native status/email/plan/API/billing rows; long email naturally moves below its label. Account actions remain separate from API access. No hero card or glass content. |
| Small / large iPhone | Single truncated title avoids a hero. Ordinary small-screen prompt and player fit. Accessibility Extra Large uses the menu selector and two-row player; text remains scrollable rather than compressed. The synthetic mock disclaimer is unusually long at this size. |
| iPad | NavigationSplitView and native toolbars retained; shared 760-point maximum detail width prevents full-width long prose. Tablet content uses the same spacing hierarchy, not inflated phone margins. |

### Accessibility, performance and acceptance limits

Semantic fonts/foregrounds/backgrounds and native controls remain in use. Timestamp and playback actions retain accessible labels, 44-point activation targets and seeking integration. Accounts communicate status through text rather than color. Increase Contrast is checked using the Simulator setting. The solid player/composer fallback is captured with an explicit DEBUG argument; **actual OS Reduce Transparency, system navigation rendering with that setting, and physical VoiceOver remain untested**. iOS 18 fallback compiles behind availability checks but no iOS 18 runtime is installed for rendering acceptance.

Custom glass surface count is bounded by the screen, not the transcript/message/library size: one player on completed Transcript/Summary; player + composer in Chat; up to three on Create Transcript including provider/Change and the prominent action. Native navigation/control surfaces are supplied by the system. Lazy transcript/chat rows, native library Lists, off-actor Markdown/search and 80 ms stream batching are retained. Explicit offline 6,000-segment, 250-message and 401-recording routes provide large-fixture rendering evidence. Gesture scrolling, frame timing, hitching during streaming and keyboard avoidance cannot be certified without device interaction access. No FPS claim is made.

A DEBUG-only final-transcript capture waits for lazy row layout before scrolling to the last row; this corrects premature screenshot positioning and changes no production navigation behavior. The final screenshot shows the complete final segment above the safe-area player. Earlier oversized Settings captures were replaced after their defect was fixed; they are not part of the final review inventory.

All physical-device behavior, interactive project/provider/reset/account workflows, sheet resizing with the keyboard, Return/newline behavior, rotation and VoiceOver remain open. Existing M11/M16.5 acceptance is not silently closed by this visual pass.

### M16.5.1 validation and integrity

Final checks on October 5, 2026:

| Check | Result |
| --- | --- |
| Full macOS tests | 454 passed, 6 expected opt-in skips, 0 failed (460 total) |
| Full iPhone Simulator tests | 49 passed, 0 failed |
| Full iPad Simulator tests | 49 passed, 0 failed |
| AudioNotes macOS Release | Build succeeded |
| AudioNotesiOS Debug Simulator | Build succeeded, including full iPhone/iPad test builds |
| AudioNotesiOS Release Simulator | Build succeeded (arm64 and x86_64) |
| Swift compiler warnings | 0 in final builds/tests |
| Build-tool warnings | Existing AppIntents metadata-extraction diagnostic remains |
| Screenshot review | 34 raw native captures + 4 before/after panels, under `docs/review/M16.5.1/` |
| `git diff --check` | Clean |

Existing behavior tests remain intact; no pixel-position tests or view-mirroring tests added. Build/test logs and result bundles are local under `/tmp/m1651-validation/`. The screenshot [inventory](review/M16.5.1/README.md) links each requested surface and documents reproduction/limits. Initial short-settle captures sometimes preceded native fixture/query/Markdown rendering on cold Simulators; these were inspected and recaptured. The script now allows eight seconds after fixture readiness. This is screenshot capture timing, not a production scroll-offset workaround or a performance result.

SwiftData models and `LibrarySchemaV1`/`LibraryMigrationPlan` are byte-identical to the baseline. Protected configuration, authentication/Keychain, OAuth registrations, resources, package resolution and release-service files also compare unchanged. The project file is restored byte-for-byte to the task-start version after Xcode's automatic `objectVersion` rewrite; **objectVersion = 77**. Signing, bundle IDs, Sparkle and release configuration remain unchanged. macOS keeps its existing summary/chat visual treatment. No new dependency or functional milestone.

**Visual review completed; ready to commit: not yet.** Required Simulator gesture/keyboard/scrolling checks remain blocked by disabled device access. Physical VoiceOver, physical devices, production signing and live providers are intentionally deferred and do not block the milestone. Actual system Reduce Transparency remains unverified, as permitted by the final acceptance instructions. Minor retained visual debt includes very large accessibility text requiring scrolling, the long synthetic mock disclaimer, shared preset/usage/history presentations, and the structured Overview label when the overview Markdown itself begins with a heading. Real provider/model sheets and live account identity states still need manual review; offline mocks deliberately do not fabricate capabilities. The extra New Project capture includes a Simulator keyboard onboarding panel, which is not app content.

M16.5 and M16.5.1 are included in commit `a73f72f` (`feat(ios): polish recording workflows and project UX`). The branch history and commit inventory confirm the implementation, tests, report, and captures are committed. No push was made as part of that milestone.

## Final M16.5 acceptance record

The final review pass on October 5, 2026 treats M16.5.1 as the visual refinement portion of M16.5. No redesign or functional change was made during this pass. M16.5 is committed at `a73f72f`; remaining device interaction is explicitly deferred acceptance and does not alter that Git state.

### Simulator visual review

Re-reviewed every image in the M16.5.1 inventory (34 raw captures and four comparisons), plus the existing AI Defaults capture from M16.5. Library, project, short/long recording titles, transcript, summary, Chat, empty/configured transcription, player, Settings and account screens have no obvious screenshot-visible blocker. Small/standard/large iPhone, iPad, Light/Dark, Accessibility Extra Large and increased contrast evidence remains valid. Content begins promptly below the selector; the final transcript segment clears the floating player. Native glass remains limited to interactive controls. No additional glass or hero/header region was introduced.

The transcription configuration captures deliberately use the existing mock provider, whose capabilities are limited; they do not establish real-provider option interaction. Account captures use synthetic identities and disabled account actions. New Project includes the documented Simulator keyboard onboarding overlay. These limits remain explicit rather than treating static captures as interaction acceptance.

### Simulator interactive acceptance — blocked

Both `device_list` and `device_open` were retried and returned **“Agent device access is turned off for this environment.”** No touch, keyboard, slider, rotation or gesture result is claimed. Domain tests establish underlying behavior separately.

| Required acceptance | Final status |
| --- | --- |
| Project create/rename/delete, move/remove, long names and sheet keyboard | Automated business logic covered; native interaction unverified |
| Player play/pause/seek, timestamp seek, scroll while playing, rotation | Unverified |
| Chat keyboard, long input, Send/Stop, mock streaming, reopen and final-message access | Unverified |
| Transcription defaults/override/reset, capability filtering, start/cancel/retry | Automated settings/filtering coverage; native interaction unverified |
| Settings destinations/back, account confirmation and long email | Visual evidence and domain tests; native interaction unverified; no real credentials touched |
| Light/Dark and increased-contrast interactions | Existing visual evidence; native interaction unverified |
| Actual system Reduce Transparency | Unverified; DEBUG opaque fallback images are not equivalent |
| Gesture scrolling: 6,000 segments / 250 messages / 401 recordings | Static fixtures reviewed; cannot classify smooth/minor hitching/problematic without gestures |

### Intentionally deferred

Physical iPhone/iPad, physical VoiceOver narration, production signing/bundle identity, live ChatGPT/Gemini acceptance and physical ChatGPT loopback lifecycle do not block this commit. Shared preset/history presentation, deeper Usage & Costs redesign, Local AI, document import, Project Chat, storage management and broader generated-document UX remain future work. No credentials or signing were changed to exercise acceptance.

### Repository state

The M16.5/M16.5.1 implementation and report are present in commit `a73f72f` on `m14-swiftui-first`. Simulator interaction is unverified because device access was disabled; it remains deferred. This documentation reconciles the earlier stale statement that the implementation was uncommitted.

### Fresh automated validation

The final review reran the full suites and builds against the unchanged implementation. Logs/result bundles are in `/tmp/m165-final/`.

| Check | Final result |
| --- | --- |
| Full macOS suite | 454 passed, 6 expected opt-in skips, 0 failed (460 total) |
| Full iPhone Simulator suite | 49 passed, 0 failed, 0 skipped |
| Full iPad Simulator suite | 49 passed, 0 failed, 0 skipped |
| macOS Release | Passed |
| iOS Debug Simulator | Passed |
| iOS Release Simulator | Passed (arm64 and x86_64) |
| New Swift compiler warnings | None |

The existing AppIntents metadata-extraction build-tool diagnostic remains. The macOS result retains the same source-processing QoS runtime diagnostic already present in the baseline result; it is not a new Swift compiler warning. Domain tests do not substitute for gesture/keyboard acceptance.

At the time of this M16.5 acceptance record, integrity checks passed against the then-current task baseline: `git diff --check` was clean; SwiftData schema/migration, signing, bundle IDs, OAuth, Sparkle, appcast/release tooling and release configuration were unchanged; and the project file had `objectVersion = 77`. The implementation and report were subsequently committed as `a73f72f`. Current M16.6 integrity results are recorded in `IOS_PROJECT_SOURCES_AND_CHAT.md`.
