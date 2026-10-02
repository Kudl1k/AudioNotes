# M16.1 — Shared / Platform Boundary Preparation

## 1. Overview & Objectives

Milestone **M16.1** prepares the AudioNotes codebase for the introduction of an iOS companion target in M16.2. 
Key design constraints honored:
- **Zero intentional macOS behavior change**: The macOS desktop app runs, compiles, and behaves identically to its pre-M16.1 state.
- **No iOS target yet**: No `AudioNotesiOS` target, no iOS bundle identifiers, no iOS entitlements or assets, and no iOS Info.plist have been added.
- **SwiftData schema 100% frozen**: Zero modifications to `@Model` classes (`Recording`, `Transcript`, `TranscriptSegment`, `Summary`, `ChatMessage`, `ChatSession`, `Project`, `RecordingSource`, `AIPreset`, `GenerationRecord`).
- **PBXPROJ preservation**: `objectVersion = 77` is strictly retained in `AudioNotes.xcodeproj/project.pbxproj` for Xcode 16 CI compatibility.

---

## 2. Platform Seams Established

### 2.1 PlatformCapabilities (`PlatformCapabilities.swift`)
A centralized query struct providing compile-time and runtime feature flags for platform-dependent features:
- `supportsClaudeCLI`: `true` on macOS, `false` elsewhere.
- `supportsSparkleUpdates`: `true` on macOS, `false` elsewhere.
- `supportsFinderReveal`: `true` on macOS, `false` elsewhere.
- `isSupported(llmProvider:)` and `isSupported(transcriptionProvider:)`: Queries supported provider IDs per platform.
- Convenience extensions on `LLMProviderID.isSupportedOnCurrentPlatform` and `TranscriptionProviderID.isSupportedOnCurrentPlatform`.

### 2.2 Cross-Platform Settings Seam (`OpenSettingsLink.swift`)
Shared feature views (`RecordingDetailView`, `ChatStatusView`, `TranscriptionControls`, `ProjectChatView`) previously hardcoded macOS SwiftUI `SettingsLink`, which does not exist or behave identically on iOS.
- Defined `OpenSettingsAction` (a callable Sendable closure isolated to `@MainActor`).
- Defined `EnvironmentValues.openSettingsAction`.
- Introduced `OpenSettingsLink`: On macOS, uses native `SettingsLink` (or an injected environment action if provided); on other platforms, uses a Button executing `openSettingsAction`.
- Eliminated all raw `SettingsLink` calls from shared feature views.

### 2.3 Cross-Platform Storage & Legacy macOS Isolation (`MacOSLegacyStorage.swift` & `AppStorageLocations.swift`)
Separated standard cross-platform paths from legacy macOS sandbox migration logic:
- `AppStorageLocations`: Provides portable properties:
  - `standardApplicationSupport`: `.applicationSupportDirectory`
  - `temporaryDirectory`: `FileManager.default.temporaryDirectory`
  - `cachesDirectory`: `.cachesDirectory`
- `MacOSLegacyStorage`: Encapsulates macOS-specific Application Support discovery and `UserDefaults` container migration (`resolveLegacyApplicationSupport`, `restoreLegacyPreferences`).
- On non-macOS platforms, `AppStorageLocations.restorePreferences()` is a clean no-op and `applicationSupport()` resolves directly against standard directories without invoking macOS sandboxing heuristics.

### 2.4 Semantic Chat Background Color (`ChatCardBackground.swift`)
Eliminated AppKit `Color(nsColor: .controlBackgroundColor)` references in shared chat views (`ChatMessageRow`, `ChatStatusView`).
- Defined `Color.chatCardBackground` using semantic SwiftUI colors:
  - macOS: `Color(nsColor: .controlBackgroundColor)`
  - Other platforms: `Color(uiColor: .secondarySystemBackground)`
- Zero occurrences of `Color(nsColor:)` remain in shared feature code.

### 2.5 CoreGraphics PDF Thumbnail Rendering (`SourceProcessingService.swift`)
Refactored PDF thumbnail rendering from AppKit `NSImage` (`page.thumbnail(of:for:)` and `NSImage.cgImage(forProposedRect:...)`) to platform-neutral CoreGraphics:
- Implemented `NativeSourceProcessingService.renderPage(_:targetSize:box:)`:\n  - Directly creates a bitmap context via `CGContext(data:width:height:bitsPerComponent:bytesPerRow:space:bitmapInfo:)`.
  - Computes scale preserving aspect ratio.
  - Applies CoreGraphics PDF coordinate transformations: translates by `(targetSize - scaledSize) / 2`, scales context, applies `page.transform(for: box)`.
  - Renders directly with `page.draw(with: box, to: context)`.
  - Extracts image via `context.makeImage()`.
- Added deterministic unit tests in `SourceProcessingTests.swift` validating both standard portrait and 90-degree rotated PDF rendering into valid CGImages.

### 2.6 Sparkle / UpdateService Isolation (`UpdateService.swift`)
Sparkle is a macOS-only update framework.
- Guarded `import Sparkle`, `SPUUpdater`, `SPUStandardUpdaterController`, and updater delegates with `#if os(macOS)`.
- Maintained a non-macOS stub for `UpdateService` satisfying public interface contracts without linking or compiling Sparkle symbols.
- Guarded Update section UI in `ProviderSettingsView.swift` behind `PlatformCapabilities.current.supportsSparkleUpdates`.

### 2.7 Claude CLI & Process Isolation (`ClaudeCLIRunner.swift` & `LLMProviderResolver.swift`)
Claude CLI utilizes Foundation `Process`, which is unavailable on iOS.
- Guarded `Process` execution in `ClaudeCLIRunner` behind `#if os(macOS)`.
- Maintained internal `UnavailableLLMProvider` throwing typed `.providerUnavailable("Claude CLI")` error when queried on unsupported platforms.
- `LLMProviderResolver` checks `PlatformCapabilities.current.supportsClaudeCLI` when resolving `.anthropic`.\n- Settings UI (`ProviderConnectionsView`, `GenerationDefaultsView`) conditionally adapts Claude CLI options based on platform capability.

---

## 3. Inventory of Remaining AppKit Touchpoints

All remaining `import AppKit` occurrences are intentionally isolated and justified:
1. `AudioNotes/Platform/macOS/AppKit/`:
   - `Alerts.swift`: Native `NSAlert` presentation for macOS dialogs.
   - `ChatTextEditorRepresentable.swift`: `NSTextView` wrapper providing macOS-specific key event handling (Enter to submit, Shift+Enter for newline).
   - `Clipboard.swift`: `NSPasteboard` helper for macOS copy/paste.
   - `FilePanels.swift`: `NSOpenPanel` and `NSSavePanel` file dialogs.
   - `PDFPreviewRepresentable.swift`: `PDFView` wrapper for macOS desktop PDF viewer.
   - `Workspace.swift`: `NSWorkspace.shared` for revealing files in macOS Finder.
2. `AudioNotes/Features/Release/ReleaseCommands.swift`:
   - macOS Main Menu items and Sparkle check-for-updates menu integration.
3. `AudioNotes/Features/Library/RecordingDragItem.swift`:
   - `NSPasteboardWriting` implementation for macOS drag-and-drop out of library to Finder.
4. `AudioNotes/Services/Export/PDFExporter.swift`:
   - `PDFExporter` uses AppKit text storage and printing formatters for macOS document rendering (already scheduled for iOS platform-seam handling in M16.6).
5. `AudioNotes/Utilities/Development/PerformanceFixtureApplicationDelegate.swift`:
   - Debug-only `NSApplicationDelegate` for automated stress testing harness.

---

## 4. Verification & Test Baseline

- **Test Suite Results**:
  - Baseline tests: 431 passed.
  - New platform tests: 6 passed (covering `PlatformCapabilities`, `OpenSettingsAction`, `AppStorageLocations`, `UnavailableLLMProvider`, and PDF CoreGraphics rendering).
  - Total: **437 tests in 78 suites passed** with 0 failures (`xcodebuild test -scheme AudioNotes -destination 'platform=macOS'`).
- **Release Build Verification**:
  - `xcodebuild build -scheme AudioNotes -configuration Release -destination 'platform=macOS'` **SUCCEEDED**.
- **PBXPROJ Integrity**:
  - `objectVersion = 77` preserved in `AudioNotes.xcodeproj/project.pbxproj`. Zero git diff.

---

## 5. M16.2 Additions: Target & UI Boundary Refinement

During M16.2, further cross-platform seams were established:
1. **FlowLayout Extraction (`Features/Shared/FlowLayout.swift`)**:
   - Extracted `FlowLayout` from macOS-specific view hierarchies into a shared layout utility for both macOS and iOS tag clouds.
2. **Browser Opening Seam (`BrowserOpening`)**:
   - Introduced `SystemBrowserOpener` on iOS utilizing `UIApplication.shared.open(_:)` while preserving `NSWorkspace.shared.open(_:)` on macOS.
3. **AppKit View Guarding**:
   - macOS-specific views (`ChatInspectorView`, `TranscriptHistoryView`, `ProjectChatSelectionView`, `SourcesView`) guarded cleanly with `#if os(macOS)` to allow root group synchronization across targets without duplicating files or perturbing project references.
