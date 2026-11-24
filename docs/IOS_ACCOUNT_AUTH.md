# M16.4 — iOS account authentication and provider capabilities

Current production identity is **Soniquill**, bundle ID `cz.kudladev.soniquill` on macOS and iOS/iPadOS. Apple Developer setup, physical iPhone installation, App Store Connect and TestFlight (initial 1.0.0 build 1, initial testers) are established, as confirmed by the owner on 2026-10-06. Milestone-era identity/signing statements below are historical and superseded by [SONIQUILL_RENAME.md](SONIQUILL_RENAME.md); individual feature acceptance is not implied. Retain legacy implementation identifiers and the working signing configuration.

Research checked **October 2, 2026** against first-party provider documentation. This report records what the APIs authorize; a connected identity is never treated as inference entitlement.

## Findings and capability matrix

| Capability | ChatGPT plan (Sign in with ChatGPT) | OpenAI API key | Google Gemini API OAuth | Gemini Advanced subscription |
|---|---|---|---|---|
| Summary | Supported through eligible Responses API requests after the user grants `chatgpt.tokens.use.direct` | Supported | Supported through Gemini Developer API `generateContent` on configured desktop or iOS OAuth | Not an API entitlement |
| Recording Chat | Supported through the same eligible Responses API path | Supported | Supported through Gemini Developer API `generateContent` on configured desktop or iOS OAuth | Not an API entitlement |
| Audio transcription | **Unsupported in AudioNotes.** SIWC authorizes eligible Responses API calls, not `/v1/audio/transcriptions`; never send plan tokens to that route. | Supported through the existing OpenAI transcription provider | Not offered; Gemini transcription was removed. | Not an API entitlement |
| Model listing | Account-specific model catalog via `GET /v1/models`; successful inference is the definitive per-model check | OpenAI API model catalog | Gemini API model catalog via configured Cloud project | No developer API catalog |

The ChatGPT-plan matrix follows OpenAI's published SIWC endpoint and preview restrictions. The SIWC documentation describes eligible Responses API calls; it does not grant permission to call `/v1/audio/transcriptions`. AudioNotes does not send recordings with a ChatGPT plan token. Gemini transcription is not offered: it required the Files API and per-minute token limits on the Free Tier cannot fit audio.

## ChatGPT identity and plan authorization

Sign in with ChatGPT has two distinct grants: identity scopes (`openid`, `profile`, `email`) and optional plan usage (`resource.invoke`, `chatgpt.tokens.use.direct`). A successful sign-in without the plan scope is identity-only and cannot enable summary/chat. The app must display the verified email and whether plan use was granted. Plus/Pro eligibility and usage limits are provider-enforced; model visibility is not an entitlement guarantee.

The official open-source flow is a public client: installation host ID, system browser authorization, random `state`, `nonce` and PKCE, `dynamic_agent_client` for first registration, then persistence of OpenAI's issued client ID before exchanging the code. Verify the ID token signature/issuer/audience/nonce and validate callback state before activating the account. No client secret is embedded. Tokens and the issued client ID are scoped to that registered session. macOS and iOS share the same ChatGPT account service. OpenAI requires the exact HTTP loopback callback `http://127.0.0.1:<port>/auth/callback`; ASWebAuthenticationSession's callback matching does not support this required loopback URI, so iOS uses the provider-controlled system browser plus a loopback listener for ChatGPT. Google uses ASWebAuthenticationSession with its registered custom scheme. No embedded WKWebView or cookie extraction is used.

**iOS loopback lifecycle status:** the implementation binds to IPv4 loopback through `NWListener`, opens the system browser, and waits in-process for the callback. Unit and Simulator tests pass. Apple documents that an iOS app is suspended shortly after backgrounding and that suspension prevents app code from running; there is no general continuous server background mode. Therefore the listener cannot be considered reliable while ChatGPT authorization has AudioNotes backgrounded. Physical callback behavior is deferred until release signing/device acceptance; the standards-compliant loopback architecture remains unchanged. [Apple background execution guidance](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time).

ChatGPT inference uses only `POST https://api.openai.com/v1/responses`, with bearer OAuth, `stream: true`, `store: false`, and the selected account model slug. Do not call ChatGPT `backend-api`. The preview rejects `temperature`, `top_p`, `max_output_tokens`, and other ordinary Responses fields; provider capabilities disable those controls for ChatGPT-plan requests while preserving saved preset values. Output length remains a prompt-level preference. Model discovery uses the authenticated account's `GET https://api.openai.com/v1/models` catalog and filters `visibility == list`; refresh it after account changes.

Access tokens expire after one hour. Read and honor `earliest_refresh_at` when supplied, refresh near expiry with the latest rotating refresh token, issued client ID, and `resource=https://api.openai.com/v1`, and serialize refreshes. Disconnect revokes the renewable session through the provider's OIDC revocation endpoint when reachable, then clears Keychain credentials and local identity metadata. If remote revocation cannot be confirmed, local credentials are still removed and the user can revoke AudioNotes in ChatGPT settings. Existing recordings and AI history are unaffected.

## Google and Gemini semantics

Google's documented Gemini OAuth path authorizes the **Gemini Developer API** using an end-user OAuth client, a Google Cloud project with Generative Language API enabled, consent-screen configuration, and API scopes. OAuth access is not Google identity alone. It does not transfer Gemini Advanced/Google AI subscription benefits to the API. API requests use the configured project's quota/billing policy (`x-goog-user-project`); users may incur API charges according to that project's billing. A Google account can connect while API use still fails due to project, billing, quota, consent, or model access.

The app's macOS path requests `openid`, `email`, `cloud-platform`, and `generative-language.retriever`, validates state, uses PKCE and the system browser, then stores access/refresh tokens in Keychain. Refresh is serialized by the OAuth actor, rotates the refresh token when returned, and clears unusable credentials on `invalid_grant`. Disconnect attempts provider revocation and always removes the local grant. No Gemini CLI credentials, browser cookies, or private endpoints are copied. The documented Google OAuth quickstart is explicitly a simplified testing flow; production deployment still requires Google consent-screen/scope review and live account validation. Google documents Gemini API OAuth at the API level; this is not a Gemini Advanced subscription path.

The iOS target currently uses development OAuth configuration: an iOS client ID, its registered reversed-client-ID callback scheme, and a non-secret Google Cloud project ID in Info.plist. Google binds an iOS OAuth client to the app's bundle identifier; its redirect scheme is derived from the OAuth client ID. The production bundle is now `cz.kudladev.soniquill`; the owner confirmed the existing Google Cloud iOS client registration was updated to that identity on 2026-10-06. The local OAuth declaration is now aligned, with the existing client ID and callback scheme retained. Configuration alignment is complete; live signed-device OAuth acceptance remains OPEN. The Console change was performed by the owner, not automatically by this task. If Google prevents editing the existing client (for example, an App Check-protected client), create a new iOS client and replace both client ID and reversed-client-ID URL scheme. The Google OAuth client Team ID is optional unless App Check is enabled; AudioNotes does not enable App Check. The current callback scheme is not derived from Apple's Team ID. macOS retains the separate Desktop client and loopback callback. Never send the iOS client through the Desktop loopback flow. [Google iOS OAuth client setup](https://developers.google.com/identity/protocols/oauth2/native-app) · [Google iOS URL scheme setup](https://developers.google.com/identity/sign-in/ios/start-integrating).

The final production bundle identifier is `cz.kudladev.soniquill`. The previous
`cz.stepankudlacek.audionotes.ios` sandbox is a development installation and must
not be migrated automatically. Existing Soniquill/TestFlight data, preferences,
Keychain credentials and OAuth state are the compatibility baseline. Preserve the
established team, bundle, provisioning and entitlements. ChatGPT's loopback redirect
is independent of bundle identifier and Apple Team ID; service/account identifiers
and installation host ID remain unchanged. Physical installation is confirmed,
but signed account continuity requires separate feature-specific evidence.

The Gemini summary/chat implementation currently uses the Gemini Developer API `generateContent` and `streamGenerateContent` endpoints with OAuth bearer credentials and the configured Cloud project. Gemini model listing and live OAuth acceptance remain manual verification items.

## Credential and provider design

- OAuth credentials (access token, refresh token, expiry) are Keychain-only. No token is written to SwiftData, preferences, files, logs, or diagnostics.
- Non-secret identity metadata (email and grant state) is display metadata. Never display a token.
- OpenAI API keys remain a separate advanced/fallback credential in Keychain. OpenAI audio transcription remains API-key authenticated; ChatGPT plan authorization does not fall through to that endpoint.
- Summary, Recording Chat, and transcription each have independent provider defaults. ChatGPT plan supports eligible summary/chat Responses requests only. Gemini OAuth supports summary and Recording Chat. OpenAI API-key transcription remains available; local Whisper remains platform-gated.
- Google OAuth client/project identifiers are developer configuration, not user credentials. A bundled Google desktop OAuth client secret is not treated as secret material; do not put provider user tokens there.
- Network operations are cancellable where supported; OAuth token refresh is actor-serialized.

## iOS, macOS, and status

Settings presents ChatGPT and Google connection controls separately from AI defaults and shows the ChatGPT plan grant separately from identity. macOS ChatGPT behavior remains on its existing shared auth service, and macOS Google OAuth uses its Desktop client. iPhone and iPad Simulator suites pass. No live credentials are used by tests. Live provider testing was not performed because no authorized real account session was available in this environment; feature-specific physical-device acceptance remains open and does not block M16.4 under the acceptance amendment.

| Evidence state | ChatGPT | Google/Gemini |
|---|---|---|
| Officially documented capability | Eligible Responses API requests; loopback callback; account model catalog | Developer API OAuth for summary and Recording Chat |
| Implemented in AudioNotes | Shared account flow, refresh/revocation, Responses summary/chat; not transcription | iOS ASWebAuthenticationSession, summary/chat, shared transcription provider |
| Automated validation | Auth/provider tests; full macOS and iPhone/iPad Simulator suites/builds | OAuth/provider/mapping tests; full macOS and iPhone/iPad Simulator suites/builds |
| Live provider tested | Not performed; no authorized real account session was available | Not performed; no authorized real account session was available |
| Physical iPhone installation | Confirmed; ChatGPT-specific device tests remain unverified | Confirmed; Google-specific device tests remain unverified |

## Physical-device feature acceptance — remaining follow-up

Apple signing, App ID setup, physical iPhone installation, App Store Connect and
TestFlight distribution are established. Do not recreate that setup to close old
M16.4 acceptance debt. Installation alone does not prove account/provider tests.
Remaining manual feature checks:

- ChatGPT: sign in and verify the loopback callback while AudioNotes is backgrounded, relaunch/account persistence, token refresh, model listing, eligible inference, and disconnect.
- Google: verify the production iOS OAuth client and callback, relaunch/Keychain persistence, token refresh, inference, and disconnect.
- Verify background/foreground transitions, VoiceOver, and device-specific audio playback.

The following live-provider sequence was not performed in this environment because no authorized real account session was available:

- **ChatGPT:** Continue with ChatGPT → authorize → confirm the loopback callback returns to/updates AudioNotes → confirm account persists after relaunch → exercise token refresh → verify authenticated account model list → send one tiny eligible Responses summary/chat request → disconnect and confirm local credentials are removed.
- **Google/Gemini:** Continue with Google → authorize in `ASWebAuthenticationSession` → confirm registered-scheme callback → confirm account persists after relaunch → exercise token refresh → verify summary → verify Recording Chat → disconnect.
- Confirm cancellation and denial paths during future live acceptance. Do not inspect or paste tokens into logs.

## Official sources consulted

- OpenAI, [Integrating Sign in with ChatGPT in your open-source app](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt) (checked 2026-10-02).
- OpenAI, [Sign in with ChatGPT overview](https://developers.openai.com/siwc/token-sharing-open-source) (checked 2026-10-02).
- OpenAI, [Sign in and register](https://developers.openai.com/siwc/token-sharing-open-source/sign-in) (checked 2026-10-02).
- OpenAI, [Accounts, sessions, refreshing, and revocation](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions) (checked 2026-10-02).
- OpenAI, [Models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference) and [preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations) (checked 2026-10-02).
- Google AI for Developers, [Gemini API OAuth quickstart](https://ai.google.dev/gemini-api/docs/oauth) (checked 2026-10-02).
- Google, [OAuth 2.0 for native apps](https://developers.google.com/identity/protocols/oauth2/native-app) (checked 2026-10-02).
- Apple, [ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession) (checked 2026-10-02).
- Google AI for Developers, [Gemini API billing](https://ai.google.dev/gemini-api/docs/billing) and [audio understanding](https://ai.google.dev/gemini-api/docs/audio) (checked 2026-10-02).
- Google AI for Developers, [Gemini model catalog](https://ai.google.dev/gemini-api/docs/models) (checked 2026-10-02).

## Follow-up — intermittent account disconnection

A Settings refresh used to treat a failed ChatGPT Keychain read as a missing
access token and erase the saved session metadata. The tokens could still be
in Keychain, but the next launch had lost the issued client ID needed to refresh
them. The restored account now survives a Keychain error and can be restored
with a refresh token alone. Settings restoration is local and runs when Settings
loads. Foregrounding itself does not clear the account. Access-token renewal
runs when an authenticated request needs it and honors the provider's earliest
refresh time while the access token is usable.

Concurrent requests now share the Keychain read and refresh operation. A network
failure leaves credentials available for the next request. If Keychain becomes
unavailable after rotation, the replacement stays in memory for a retry of the
write without reusing the old token. This recovery requires the process to survive
until the write succeeds. An exact terminal OAuth refresh code clears the tokens
and updates the UI, retaining the issued client mapping for reauthorization.
Manual disconnect waits for current refresh work, attempts revocation, and clears
local credentials and metadata. Existing token accessibility and Keychain lookup
identities are preserved.

For a signed-device check, install the updated build over the existing Soniquill
installation. In **Settings → ChatGPT**, confirm the existing account and plan
access, then run a short eligible chat request. Lock the device and move the app
to the background, return, and reopen Settings. After the access token approaches
expiry, briefly disable both Wi-Fi and cellular, attempt a request, restore the
network, and retry. Check for `ChatGPTOAuth` / `refresh: saved` in macOS Console for
the connected iPhone. Force-quit and reopen to confirm the renewed session is
restored. Verify remote revocation and local disconnect separately with a test
account. For remote revocation, remove the grant in ChatGPT and exercise refresh,
then confirm Settings offers sign-in. For local disconnect, confirm the app still
offers sign-in following relaunch. A first-time ChatGPT sign-in should also be
tested with Safari foregrounded long enough for the app to become suspended.
