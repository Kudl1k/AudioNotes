# Google OAuth developer configuration

Download the Desktop OAuth client JSON from your Google Cloud project and place it at `AudioNotes/Resources/GoogleOAuth.json` (create the Resources directory if needed). Xcode’s synchronized AudioNotes group includes this JSON in the app’s resources. Rebuild the app after changing the file. The actual configuration is ignored by Git.

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
