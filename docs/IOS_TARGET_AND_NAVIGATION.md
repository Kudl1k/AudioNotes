# M16.2 — iOS Target & Native Navigation Shell

## 1. Executive Summary

Milestone **M16.2** introduces the native iOS and iPadOS companion application target (`AudioNotesiOS`) into the AudioNotes codebase. This milestone establishes the native application target, its configuration, and its adaptive navigation shell running the real AudioNotes architecture on real iOS and iPadOS simulators.

Key accomplishments:
- **Real Codebase Reuse**: Reuses existing SwiftData persistence (`LibrarySchemaV1`), repositories (`ProjectRepository`, `UsageRepository`), domain models (`Recording`, `Project`, `Transcript`, `Summary`, etc.), and view models (`LibraryViewModel`, `RecordingDetailViewModel`, `ProjectWorkspaceViewModel`).
- **PBXProject Integrity**: Created `AudioNotesiOS` target maintaining `objectVersion = 77;` intact in `AudioNotes.xcodeproj/project.pbxproj`, preventing Xcode 27 / Xcode 16 format corruption.
- **Adaptive Native Shell**:
  - **iPhone (compact width)**: Native `NavigationStack` with drill-down navigation from Library root to Recordings and Projects.
  - **iPad (regular width)**: Native `NavigationSplitView` with sidebar and detail panes, avoiding clumsy 3-column macOS desktop replication.
- **Provider & Feature Gating**:
  - Sparkle updates completely excluded (no framework linkage, no update UI).
  - Claude CLI hidden on iOS via `PlatformCapabilities.supportsClaudeCLI`.
  - WhisperKit compilation excluded on iOS for M16.2 (deferred to M16.7 spike).
- **Verified Simulator Acceptance**:
  - iPhone 17 simulator: Built, installed, and launched cleanly (PID 15309 / 15346).
  - iPad (A16) simulator: Built, installed, and launched cleanly (PID 17294 / 17960).
  - Zero crashes, zero database corruption, zero regressions on macOS test suite (437 tests passing).

---

## 2. Target Configuration & Build Setup

### 2.1 Configuration File (`Configuration/iOS.xcconfig`)
Target-level build settings are isolated in a dedicated configuration file:
- `SDKROOT = iphoneos`
- `SUPPORTED_PLATFORMS = iphonesimulator iphoneos`
- `TARGETED_DEVICE_FAMILY = 1,2` (iPhone and iPad)
- `IPHONEOS_DEPLOYMENT_TARGET = 18.0`
- `PRODUCT_NAME = AudioNotes`
- `PRODUCT_BUNDLE_IDENTIFIER = cz.stepankudlacek.audionotes.ios` (provisional development identifier)
- `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`
- `SWIFT_VERSION = 6.0`
- `SWIFT_APPROACHABLE_CONCURRENCY = YES`

### 2.2 Xcode Project Integration
- **Target**: `AudioNotesiOS` native application target in `AudioNotes.xcodeproj/project.pbxproj`.
- **Scheme**: `AudioNotes.xcodeproj/xcshareddata/xcschemes/AudioNotesiOS.xcscheme` (shared scheme).
- **Format Preservation**: `objectVersion = 77;` retained. No `objectVersion = 110` written.
- **Asset Catalog**: `Assets.xcassets/AppIcon.appiconset/Contents.json` updated with universal 1024x1024 iOS icon entry.

### 2.3 Dependency Linkage and Exclusions
- **Sparkle Framework**: Not linked to `AudioNotesiOS`. `UpdateService.swift` uses `#if os(macOS)` to exclude Sparkle symbols on iOS.
- **WhisperKit**: Excluded from `AudioNotesiOS` linkage. `LocalWhisperTranscriptionProvider` is guarded with `#if os(macOS)`.
- **AppKit Isolation**: macOS-specific UI views (`ChatInspectorView.swift`, `TranscriptHistoryView.swift`, `ProjectChatSelectionView.swift`, `SourcesView.swift`) and DEBUG test fixtures (`Utilities/Development/*.swift`) are guarded with `#if os(macOS)` or `#if DEBUG && os(macOS)`.

---

## 3. Native Adaptive Navigation Shell

### 3.1 App Entry Point (`AudioNotesiOSApp.swift`)
```swift
#if os(iOS)
@main
struct AudioNotesiOSApp: App {
    @State private var services = AppServices()
    @State private var startup = LibraryStartup()
    private var container: ModelContainer? { startup.container }

    var body: some Scene {
        WindowGroup {
            if let container {
                IOSRootView(services: services)
                    .modelContainer(container)
                    .environment(services.llmConfiguration.localAI)
            } else {
                LibraryRecoveryView(startup: startup)
            }
        }
    }
}
#endif
```

### 3.2 Adaptive Navigation Root (`IOSRootView.swift`)
The root view adapts dynamically based on `@Environment(\.horizontalSizeClass)`:

```
               ┌──────────────────────────────────────────────┐
               │                 IOSRootView                  │
               └──────────────────────┬───────────────────────┘
                                      │
                   ┌──────────────────┴──────────────────┐
                   ▼                                     ▼
        Compact Width (iPhone)                Regular Width (iPad)
     ┌────────────────────────────┐       ┌────────────────────────────┐
     │      NavigationStack       │       │    NavigationSplitView     │
     │                            │       │ ┌────────────┬───────────┐ │
     │  - Library Top-Level List  │       │ │  Sidebar   │  Detail   │ │
     │    - All Recordings Row    │       │ │  - Library │           │ │
     │    - Projects Section      │       │ │  - Recs    │  Selected │ │
     │  - Navigation Destinations │       │ │  - Projs   │   View    │ │
     │    - .allRecordings        │       │ └────────────┴───────────┘ │
     │    - .project(UUID)        │       └────────────────────────────┘
     └────────────────────────────┘
```

- **Compact (iPhone)**:
  - Uses `NavigationStack` with explicit navigation destinations.
  - Root presents summary of recordings and project folders.
  - Drill-down transitions cleanly to `IOSAllRecordingsView` and `IOSProjectWorkspaceShell`.
  - Bottom toolbar provides quick access to Settings via modal sheet.
- **Regular (iPad)**:
  - Uses `NavigationSplitView(columnVisibility:)`.
  - Sidebar provides quick switching between All Recordings and Projects.
  - Detail pane hosts the selected destination, sharing the `LibraryDestination` enum with macOS.
  - Navigation title and toolbar actions integrate seamlessly into iPadOS navigation bar.

### 3.3 Destination Shells
- **Recording Detail (`IOSRecordingDetailShell.swift`)**:
  - Displays recording title, creation timestamp, duration, and status pill.
  - Formatted transcript segment list with timestamp badges.
  - Summary card showing markdown summary content.
  - Action button placeholders for future M16.3 / M16.4 capabilities (playback controls, re-transcribe, export).
- **Project Workspace (`IOSProjectWorkspaceShell.swift`)**:
  - Project title, description, and status tags.
  - Member recordings list with navigation into recording details.
  - Attached sources list (PDF, text, OCR images).
  - Project Chat placeholder tab for M16.5.
- **Native iOS Settings (`IOSSettingsView.swift`)**:
  - Sectioned form with toggle switches for OpenAI, Ollama, and Local AI endpoints.
  - Default model picker menus.
  - Privacy policy and licenses modal sheets.
  - System browser link opener using `UIApplication.shared.open`.
  - Claude CLI configuration and Sparkle updates are explicitly hidden.

---

## 4. Persistence & Storage Isolation

### 4.1 Sandbox Container
On iOS, the application uses standard sandbox container directories:
- Application Support: `.../data/Containers/Data/Application/<UUID>/Library/Application Support/AudioNotes/`
- Database URL: `.../AudioNotes/Library.store`
- Recordings directory: `.../AudioNotes/Recordings/`

### 4.2 Storage Isolation Verification
- The iOS simulator environment operates entirely inside its isolated device container.
- Zero reads, writes, or locks are attempted against macOS desktop databases or files (`~/Library/Application Support/AudioNotes`).
- `LibrarySchemaV1` and `LibraryMigrationPlan` are used without modification. A fresh launch on iOS initializes an empty database without schema errors.

---

## 5. Verification & Acceptance

### 5.1 Automated Test Suites & Regression Verification
- **macOS Full Test Suite**:
  ```bash
  xcodebuild test -project AudioNotes.xcodeproj -scheme AudioNotes -destination 'platform=macOS'
  ```
  Result: **`** TEST SUCCEEDED **`** (437 tests across 78 test suites passed, 0 failures).
- **macOS Release Build**:
  ```bash
  xcodebuild build -project AudioNotes.xcodeproj -scheme AudioNotes -configuration Release -destination 'platform=macOS'
  ```
  Result: **`** BUILD SUCCEEDED **`**.
- **iOS Generic Simulator Build**:
  ```bash
  xcodebuild build -project AudioNotes.xcodeproj -scheme AudioNotesiOS -destination 'generic/platform=iOS Simulator'
  ```
  Result: **`** BUILD SUCCEEDED **`**.

### 5.2 Simulator Acceptance
- **iPhone 17 Simulator** (`D43BE5A3-25CD-462A-82AA-220DC5A8543C`):
  - Application installed and launched cleanly (`PID 15309`, `PID 15346`).
  - Compact `NavigationStack` UI displayed with Library, Recordings, Projects, and Settings.
  - Screenshot verified: `audionotes_iphone.png`.
- **iPad (A16) Simulator** (`7B6C4E54-81A5-4549-8D49-3F54F3816126`):
  - Application installed and launched cleanly (`PID 17294`, `PID 17960`).
  - Regular `NavigationSplitView` UI displayed with Sidebar and Detail panes.
  - Screenshot verified: `audionotes_ipad.png`.
- **Zero Crashes**: Application lifecycle transitions (foreground, active, background, terminate) completed without unhandled exceptions.

---

## 6. Artifacts and Uncommitted State

M16.2 was verified and committed separately on 2026-10-02 as
`52d62a3284d5cfd777b02a7ad87a7805e551125a` (`feat(ios): add native app target and navigation shell`).
Nothing was pushed; the working tree was clean before M16.3.

## 7. M16.3 follow-up

The recording shell and import placeholder are now replaced by native multi-file
Files import, foreground playback, read-only transcript/summary/history, rename
and confirmed deletion. Compact and split navigation remain native and share the
same workflow. Project/source/AI/export workflows remain deferred.

M16.2 contained no runnable iOS test target. M16.3 adds `AudioNotesTests-iOS` using
selected existing portable test files and the shared scheme (26 tests/6 suites).
macOS now passes 442 tests/79 suites. SwiftData schema and migration are unchanged.
See [iOS audio and recording report](IOS_AUDIO_AND_RECORDING.md) for exact
architecture, builds, native acceptance, screenshots and remaining device checks.
