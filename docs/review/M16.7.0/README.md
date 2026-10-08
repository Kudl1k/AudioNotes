# Soniquill rename visual review

Synthetic DEBUG fixtures only. No real library, account credentials, live OAuth,
model downloads or metered provider requests were used. Screens establish branding
and representative layout, not full gesture/VoiceOver or production-install acceptance.
The capture-time device tool reported access disabled; Simulator captures use existing launch flags
and `simctl`. macOS captures use the isolated DEBUG fixture window and window-only
screen capture, with a cleared process environment. No desktop-wide/private-content
screenshot or environment/log archive is checked in.

Apple release state was subsequently corrected by the owner: physical iPhone
installation and TestFlight distribution of Soniquill 1.0.0 build 1 are confirmed.
These screenshots do not prove individual physical-device feature tests. Google
account screenshots precede the owner-confirmed Console bundle update and local
configuration alignment; they are synthetic visual evidence, not live OAuth proof.
See [the final release baseline and validation](../../SONIQUILL_RENAME.md).

## Captures

| Group | Device/surface | Screens |
| --- | --- | --- |
| `iphone/` | iPhone 17e, iOS 26.5 Simulator | Library Light/Dark; recording Dark; Settings Light and accessibility size; project Light; populated Project Chat Dark; mock account/provider Settings |
| `small/` | Existing M16.5 Small iPhone fixture, iOS 26.5 | Library Light/Dark; recording Dark; Settings Light and accessibility size; project Light; populated Project Chat Dark |
| `ipad/` | iPad Pro 11-inch M5, iOS 26.5 Simulator | Sidebar/library Light/Dark; recording Dark; Settings Light and accessibility size; project Light; Project Chat Dark |
| `macos/` | Native isolated desktop fixtures | Library/project/recording Light; local Settings component Light; system About and Help Dark |

The product name fits standard/small iPhone library headings and the iPad sidebar.
Settings uses About Soniquill; Project Chat assistant headers use Soniquill.
Native macOS app menu was inspected: About Soniquill, Hide Soniquill, Quit Soniquill;
Help is Soniquill Help. There is no visible stale product branding in reviewed screens.
Window/recording titles may use user/fixture titles; the long DEBUG Development Fixtures
suffix can truncate in a toolbar, while the actual Soniquill name remains readable.
Accessibility sizes wrap content naturally; no name-specific visual redesign was needed.
Some views contain scrollable content below the captured viewport.

macOS Settings capture is the existing isolated LocalAISettingsView fixture, not the
live account/preferences window (which would query real Keychain state). Its synthetic
16 KiB downloadable items are not real model data; no download action was performed.
Native General/account Settings and the full accessibility/About navigation on iOS
remain manual acceptance. Standard iPad Settings was recaptured after its presentation
finished; the first startup-frame image was replaced. Library images may show an empty
fixture library, while recording/project images establish populated layouts. Existing
historical screenshots from earlier milestones retain the old name by design.

## Reproduction

Build the unsigned Debug Simulator app at `/tmp/Soniquill-Rename-ios`, then run from
repository root (use a Simulator ID, never a physical device):

```sh
python3 docs/review/M16.7.0/capture.py <simulator-uuid> iphone
python3 docs/review/M16.7.0/capture.py <small-simulator-uuid> small
python3 docs/review/M16.7.0/capture.py <ipad-simulator-uuid> ipad
```

Override `--app` if using another DerivedData path. This script boots/installs only
Simulators, uses in-memory startup and the isolated temporary fixture root, waits for
fixture readiness and presentation, then restores Light/default content size. Account
captures additionally use `--ios-review-settings --ios-review-chatgpt` or
`--ios-review-settings --ios-review-gemini` with the same fixture flags; they do not
invoke sign-in. Fixture import dates are runtime dates; these are synthetic-content
captures, not a promise of pixel-identical timestamps.

macOS uses the Debug executable with `--performance-fixtures --performance-light`:
`--performance-project-chat` for the populated project, `--performance-recording small
--performance-tab transcript` for the recording, and `--performance-operation-settings`
for the isolated Local AI Settings surface. About/Help use native app-menu commands.
