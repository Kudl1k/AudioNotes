# M16.4 — iOS account authentication and provider capabilities

Research checked **October 2, 2026** against first-party provider documentation. This report records what the APIs authorize; a connected identity is never treated as inference entitlement.

## Findings and capability matrix

| Capability | ChatGPT plan (Sign in with ChatGPT) | OpenAI API key | Google Gemini API OAuth | Gemini Advanced subscription |
|---|---|---|---|---|
| Summary | Supported through eligible Responses API requests after the user grants `chatgpt.tokens.use.direct` | Supported | Supported through Gemini Developer API `generateContent` on configured desktop or iOS OAuth | Not an API entitlement |
| Recording Chat | Supported through the same eligible Responses API path | Supported | Supported through Gemini Developer API `generateContent` on configured desktop or iOS OAuth | Not an API entitlement |
| Audio transcription | **Unsupported in AudioNotes.** SIWC authorizes eligible Responses API calls, not `/v1/audio/transcriptions`; never send plan tokens to that route. | Supported through the existing OpenAI transcription provider | Implemented through the shared `TranscriptionProvider` using Gemini 3.5 Transcribe, Files API and Interactions API; word timestamps and speaker diarization map to existing segment fields. | Not an API entitlement |
| Model listing | Account-specific model catalog via `GET /v1/models`; successful inference is the definitive per-model check | OpenAI API model catalog | Gemini API model catalog via configured Cloud project | No developer API catalog |

The ChatGPT-plan matrix follows OpenAI's published SIWC endpoint and preview restrictions. The SIWC documentation describes eligible Responses API calls; it does not grant permission to call `/v1/audio/transcriptions`. AudioNotes does not send recordings with a ChatGPT plan token. Gemini transcription is implemented with the official `gemini-3.5-transcribe` Interactions API. AudioNotes requests verbatim mode with word timestamps and diarization and rejects recordings over the documented 30-minute limit for either feature. It uploads managed audio through Google's Files API (2 GB per-file ceiling, 48-hour server retention) and schedules explicit deletion once Google's uploaded-file handle is returned, regardless of transcription success, failure, or subsequent cancellation. If upload cancellation happens before AudioNotes receives the file handle, remote deletion cannot be confirmed; Google expires Files API uploads within 48 hours. Automated request/mapping tests pass; live provider acceptance remains pending.

## ChatGPT identity and plan authorization

Sign in with ChatGPT has two distinct grants: identity scopes (`openid`, `profile`, `email`) and optional plan usage (`resource.invoke`, `chatgpt.tokens.use.direct`). A successful sign-in without the plan scope is identity-only and cannot enable summary/chat. The app must display the verified email and whether plan use was granted. Plus/Pro eligibility and usage limits are provider-enforced; model visibility is not an entitlement guarantee.

The official open-source flow is a public client: installation host ID, system browser authorization, random `state`, `nonce` and PKCE, `dynamic_agent_client` for first registration, then persistence of OpenAI's issued client ID before exchanging the code. Verify the ID token signature/issuer/audience/nonce and validate callback state before activating the account. No client secret is embedded. Tokens and the issued client ID are scoped to that registered session. macOS and iOS share the same ChatGPT account service. OpenAI requires the exact HTTP loopback callback `http://127.0.0.1:<port>/auth/callback`; ASWebAuthenticationSession's callback matching does not support this required loopback URI, so iOS uses the provider-controlled system browser plus a loopback listener for ChatGPT. Google uses ASWebAuthenticationSession with its registered custom scheme. No embedded WKWebView or cookie extraction is used.

**iOS loopback lifecycle status:** the implementation binds to IPv4 loopback through `NWListener`, opens the system browser, and waits in-process for the callback. Unit and Simulator tests pass. Apple documents that an iOS app is suspended shortly after backgrounding and that suspension prevents app code from running; there is no general continuous server background mode. Therefore the listener cannot be considered reliable while ChatGPT authorization has AudioNotes backgrounded. Physical callback behavior is deferred until release signing/device acceptance; the standards-compliant loopback architecture remains unchanged. [Apple background execution guidance](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time).

ChatGPT inference uses only `POST https://api.openai.com/v1/responses`, with bearer OAuth, `stream: true`, `store: false`, and the selected account model slug. Do not call ChatGPT `backend-api`. The preview rejects `temperature`, `top_p`, `max_output_tokens`, and other ordinary Responses fields; provider capabilities disable those controls for ChatGPT-plan requests while preserving saved preset values. Output length remains a prompt-level preference. Model discovery uses the authenticated account's `GET https://api.openai.com/v1/models` catalog and filters `visibility == list`; refresh it after account changes.

Access tokens expire after one hour. Read and honor `earliest_refresh_at` when supplied, refresh near expiry with the latest rotating refresh token, issued client ID, and `resource=https://api.openai.com/v1`, and serialize refreshes. Disconnect revokes the renewable session through the provider's OIDC revocation endpoint when reachable, then clears Keychain credentials and local identity metadata. If remote revocation cannot be confirmed, local credentials are still removed and the user can revoke AudioNotes in ChatGPT settings. Existing recordings and AI history are unaffected.

## Google and Gemini semantics

Google's documented Gemini OAuth path authorizes the **Gemini Developer API** using an end-user OAuth client, a Google Cloud project with Generative Language API enabled, consent-screen configuration, and API scopes. OAuth access is not Google identity alone. It does not transfer Gemini Advanced/Google AI subscription benefits to the API. API requests use the configured project's quota/billing policy (`x-goog-user-project`); users may incur API charges according to that project's billing. A Google account can connect while API use still fails due to project, billing, quota, consent, or model access.

The app's macOS path requests `openid`, `email`, `cloud-platform`, and `generative-language.retriever`, validates state, uses PKCE and the system browser, then stores access/refresh tokens in Keychain. Refresh is serialized by the OAuth actor, rotates the refresh token when returned, and clears unusable credentials on `invalid_grant`. Disconnect attempts provider revocation and always removes the local grant. No Gemini CLI credentials, browser cookies, or private endpoints are copied. The documented Google OAuth quickstart is explicitly a simplified testing flow; production deployment still requires Google consent-screen/scope review and live account validation. Google documents Gemini API OAuth at the API level; this is not a Gemini Advanced subscription path.

The iOS target currently uses development OAuth configuration: an iOS client ID, its registered reversed-client-ID callback scheme, and a non-secret Google Cloud project ID in Info.plist. Google binds an iOS OAuth client to the app's bundle identifier; its redirect scheme is derived from the OAuth client ID. When the production bundle identifier is chosen, update the Google iOS OAuth client registration and app configuration. If Google prevents editing the existing client (for example, an App Check-protected client), create a new iOS client and replace both client ID and reversed-client-ID URL scheme. The Google OAuth client Team ID is optional unless App Check is enabled; AudioNotes does not enable App Check. The current callback scheme is not derived from Apple's Team ID. macOS retains the separate Desktop client and loopback callback. Never send the iOS client through the Desktop loopback flow. [Google iOS OAuth client setup](https://developers.google.com/identity/protocols/oauth2/native-app) · [Google iOS URL scheme setup](https://developers.google.com/identity/sign-in/ios/start-integrating).

The current `cz.stepankudlacek.audionotes.ios` bundle identifier is a development/project value, not a finalized production identity. ChatGPT's required `127.0.0.1` redirect is independent of bundle identifier and Apple Team ID. Its issued client ID and installation host ID belong to the auth session. The app's Keychain items use the platform's default app access group; changing the signing team or bundle identity may make existing credentials inaccessible, so account reauthorization should be expected unless a valid same-team migration path is established. Signing was not changed; existing iOS project settings contain a `DEVELOPMENT_TEAM` value with automatic signing, while Simulator builds use code-sign identity `-`. Ownership of that existing team value was not verified, and no new personal team was selected. No production App ID, production capability, App Store Connect record, certificate, or provisioning profile was created for this work.

The Gemini summary/chat implementation currently uses the Gemini Developer API `generateContent` and `streamGenerateContent` endpoints with OAuth bearer credentials and the configured Cloud project. Transcription uses `v1beta/interactions` with Gemini 3.5 Transcribe. It maps `word_info` offsets to `TranscriptSegment.startTime/endTime` and anonymous diarization IDs to “Speaker N”; schema-frozen metadata such as Gemini's confidence values, word-level annotation types, or richer speaker metadata cannot be retained. Google does not expose a transcription duration cost estimate in the interaction response currently consumed, so transcription cost remains unavailable rather than zero. Gemini model listing and live OAuth acceptance remain manual verification items.

## Credential and provider design

- OAuth credentials (access token, refresh token, expiry) are Keychain-only. No token is written to SwiftData, preferences, files, logs, or diagnostics.
- Non-secret identity metadata (email and grant state) is display metadata. Never display a token.
- OpenAI API keys remain a separate advanced/fallback credential in Keychain. OpenAI audio transcription remains API-key authenticated; ChatGPT plan authorization does not fall through to that endpoint.
- Summary, Recording Chat, and transcription each have independent provider defaults. ChatGPT plan supports eligible summary/chat Responses requests only. Gemini OAuth supports summary, Recording Chat, and Gemini transcription. OpenAI API-key transcription remains available; local Whisper remains platform-gated.
- Google OAuth client/project identifiers are developer configuration, not user credentials. A bundled Google desktop OAuth client secret is not treated as secret material; do not put provider user tokens there.
- Network operations are cancellable where supported; OAuth token refresh is actor-serialized.

## iOS, macOS, and status

Settings presents ChatGPT and Google connection controls separately from AI defaults and shows the ChatGPT plan grant separately from identity. macOS ChatGPT behavior remains on its existing shared auth service, and macOS Google OAuth uses its Desktop client. iPhone and iPad Simulator suites pass. No live credentials are used by tests. Live provider testing was not performed because no authorized real account session was available in this environment; physical-device acceptance is intentionally deferred and does not block M16.4 under the acceptance amendment.

| Evidence state | ChatGPT | Google/Gemini |
|---|---|---|
| Officially documented capability | Eligible Responses API requests; loopback callback; account model catalog | Developer API OAuth; Gemini 3.5 Transcribe timestamps/diarization and documented limits |
| Implemented in AudioNotes | Shared account flow, refresh/revocation, Responses summary/chat; not transcription | iOS ASWebAuthenticationSession, summary/chat, shared transcription provider |
| Automated validation | Auth/provider tests; full macOS and iPhone/iPad Simulator suites/builds | OAuth/provider/mapping tests; full macOS and iPhone/iPad Simulator suites/builds |
| Live provider tested | Not performed; no authorized real account session was available | Not performed; no authorized real account session was available |
| Physical iPhone tested | Deferred until final Apple Team/bundle identity and release signing are selected | Deferred until final Apple Team/bundle identity and release signing are selected |

## Physical Device / Signing Acceptance — deferred release work

This manual acceptance debt belongs to the release/signing milestone and does not block M16.4. Do not select a personal Developer Team, register the development bundle ID, create profiles/certificates, or install on a physical phone to close M16.4. When the owning Apple Developer Team and permanent bundle ID are finalized, the release handoff must cover:

- Confirm the final company Developer Team and permanent production bundle identifier; register the production App ID and required capabilities only then.
- Configure provisioning/signing and install on a physical iPhone; then prepare TestFlight/App Store records in the release milestone.
- ChatGPT: sign in and verify the loopback callback while AudioNotes is backgrounded, relaunch/account persistence, token refresh, model listing, eligible inference, and disconnect.
- Google: verify the production iOS OAuth client and callback, relaunch/Keychain persistence, token refresh, inference, and disconnect.
- Verify background/foreground transitions, VoiceOver, and device-specific audio playback.

The following live-provider sequence was not performed in this environment because no authorized real account session was available:

- **ChatGPT:** Continue with ChatGPT → authorize → confirm the loopback callback returns to/updates AudioNotes → confirm account persists after relaunch → exercise token refresh → verify authenticated account model list → send one tiny eligible Responses summary/chat request → disconnect and confirm local credentials are removed.
- **Google/Gemini:** Continue with Google → authorize in `ASWebAuthenticationSession` → confirm registered-scheme callback → confirm account persists after relaunch → exercise token refresh → verify summary → verify Recording Chat → transcribe a short harmless audio fixture and verify persisted timestamped transcript, seek, history and usage/cost state → disconnect.
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
- Google AI for Developers, [Gemini 3.5 Transcribe model](https://ai.google.dev/gemini-api/docs/models/gemini-3.5-transcribe), [audio transcription API](https://ai.google.dev/gemini-api/docs/transcribe), and [Gemini model catalog](https://ai.google.dev/gemini-api/docs/models) (checked 2026-10-02).
