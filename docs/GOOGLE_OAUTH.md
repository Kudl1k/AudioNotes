# Google OAuth developer configuration

Download the Desktop OAuth client JSON from your Google Cloud project and place it at `AudioNotes/Resources/GoogleOAuth.json` (create the Resources directory if needed). The synchronized AudioNotes group excludes this developer JSON from normal app resources; only an explicitly configured development build should include it. Rebuild after changing developer configuration. The actual configuration is ignored by Git.

Use Google’s downloaded `installed` format, including `client_id`, `project_id`, and the optional `client_secret`. For example:

```json
{
  "installed": {
    "client_id": "YOUR_DESKTOP_CLIENT_ID.apps.googleusercontent.com",
    "project_id": "YOUR_GOOGLE_CLOUD_PROJECT_ID"
  }
}
```

Keep the downloaded optional `client_secret` field if your client requires it. The app reads this developer file automatically and synchronizes the secret into macOS Keychain before authentication. Access and refresh tokens are stored only in Keychain. A native app’s bundled desktop client secret is available to anyone with the application; it is not a confidential server credential. Do not put API keys or account tokens in this file.

Settings shows configuration availability and Google sign-in/disconnect controls. Users cannot enter or replace the OAuth client ID, project ID, or secret. Legacy preference values and user-entered OAuth secrets are no longer used. Missing, unreadable, malformed, or non-Desktop configuration disables sign-in and reports a configuration error without exposing file contents. Gemini API-key authentication remains independently available.

A real developer configuration is required for browser sign-in acceptance; no credentials are shipped in the repository.

## Soniquill identity

macOS Desktop OAuth remains independent of the Apple bundle ID. On 2026-10-06 the
owner confirmed the existing iOS client's Google Cloud Console bundle registration
was changed to `cz.kudladev.soniquill`. The local `GoogleOAuthClientBundleIdentifier`
in `Configuration/iOS-Info.plist` is now aligned. Client ID, reversed callback scheme
(including `CFBundleURLTypes`/xcconfig), and project ID are unchanged. The existing
bundle-mismatch guard is retained and tests verify the production configuration loads.

Configuration is aligned. Signed iPhone verification confirmed the callback and
Keychain write in Console. The owner confirmed that the connection persisted
after relaunch. Live inference, token refresh and disconnect remain open.
The Console change is owner-reported, not independently inspected by this task.
No Google Cloud credentials were changed automatically. No replacement TestFlight
build was uploaded; the local declaration applies to the next authorized build.
If a replacement client is needed, manually update its issued client ID and matching
reversed scheme together; keep `cz.kudladev.soniquill` as the bundle declaration.
See [authentication and continuity details](SONIQUILL_RENAME.md#authentication-and-url-schemes).

## Diagnosing sign-in on a signed iPhone

The built app checks the actual bundle ID, iOS client ID format, and the registered
reversed-client-ID URL scheme. The system authentication session uses a foreground
window. The callback must match the expected scheme, path, and state. Authorization
and exchange use the same single-slash redirect URI and S256 PKCE. The app persists
the renewable grant even when the optional user-info request fails. macOS uses the
separate Desktop client and its dynamic loopback redirect.
[Google's iOS client setup](https://developers.google.com/identity/sign-in/ios/api-access)
· [AppAuth iOS redirect example](https://github.com/openid/AppAuth-iOS/blob/master/Examples/README-Google.md)
· [Gemini OAuth scopes and quota project](https://ai.google.dev/gemini-api/docs/oauth)

1. Connect the signed iPhone to the Mac, open Console, select the iPhone, and
   filter by subsystem `cz.kudladev.soniquill` and category `GoogleOAuth`.
   In **Settings → Google / Gemini**, tap **Continue with Google**, grant access,
   and confirm the app displays **Connected**. On failure, record only the stage,
   category, and any HTTP status or standard OAuth error code. If Google's page
   stops before redirecting, record the displayed error code without its URL or
   account details. The expected log sequence is `browser: starting`,
   `callback: verified`, then `keychainSave: connected`.
2. Select Gemini OAuth for Chat and submit a short question about a test recording.
   Force-quit and relaunch, confirm the connection and repeat. After the access
   token approaches expiry, send another request and verify `refresh: saved`
   and a successful result. In Settings, disconnect and relaunch to confirm the
   local grant is gone.
3. For a browser-side client or redirect error, open **Google Auth Platform →
   Clients** in the configured Cloud project. Open the exact client ID present in
   the built app's `GoogleOAuthClientID`. Verify **Application type: iOS**,
   **Bundle ID: cz.kudladev.soniquill**, and **iOS URL scheme** equals the
   registered value in `CFBundleURLTypes`. Check whether **Protect your OAuth
   client from abuse with Firebase App Check** is enabled or enforced if Google
   reports a client attestation error. The current app does not send App Check
   tokens. For consent errors, check **Audience** (Internal/External, publishing
   status and Test users) and **Data Access** (requested scopes and verification).
4. If connecting succeeds and only inference fails, check that **APIs & Services →
   Enabled APIs & services** includes **Generative Language API** in the quota
   project. Check the project's billing, quota, and the test user's permission to
   use that project. Treat a browser error and an API permission error as separate
   observations.
