# Claude Code account integration

AudioNotes can use an installed Claude Code executable for Anthropic summaries and
recording chat. The application remains Swift/SwiftUI; there is no backend service
or embedded Node runtime. The CLI is an external, user-installed dependency.

## Setup

1. Install a current native Claude Code release using the [official instructions](https://code.claude.com/docs/en/setup).
2. In AudioNotes, open Settings → Anthropic. Leave the executable path blank for
   automatic discovery (`~/.local/bin/claude`, Homebrew locations, then `PATH`), or
   enter an absolute path.
3. Click **Sign in with Claude Code…**, complete the CLI's browser login, and
   refresh the connection. An existing `claude auth login` session is also usable.
4. In Settings → General, select **Anthropic Claude** independently for summaries
   and chat. Model dropdowns load the model names reported by your signed-in CLI;
   choose summary and chat models independently. The connection page and both
   dropdowns offer **Refresh Claude Models**. Previously saved model IDs remain
   selected when a refresh no longer lists them. Preset provider/model overrides
   use the same CLI path.

AudioNotes requires the CLI's `claude.ai` / `firstParty` account authentication.
It rejects API-key, Console and third-party-cloud authentication and never falls
back to another credential or model. No login is performed automatically. Logout
is managed in Claude Code because the login is shared with other CLI clients.

## Model discovery

Model discovery sends only an Agent SDK `initialize` control request over
`--input-format stream-json`, then closes stdin. The correlated initialization
response contains the CLI's model choices (`value`, `displayName`, `description`,
optional `resolvedModel`). No user prompt, recording content, or generation request
is sent. The same tool/customization isolation flags apply. The metadata probe has
an independent thirty-second timeout and requires a supported Claude account login.

Non-secret model labels/IDs are cached in preferences for the configured executable.
Changing the executable clears the cache. Refresh failures retain the last successful
list and show a recoverable error; they never switch selected models. Discovery is
shared between summary/chat settings to avoid duplicate simultaneous probes.

## Execution and privacy

`ClaudeCLIRunning` provides an injectable process boundary. `ClaudeCLIClient`
checks `claude auth status` before each request, then runs print mode using the
documented JSON-schema and streaming interfaces. `ClaudeCLILLMProvider` implements
the existing LLMProvider protocol, including unified-source summaries and chat.

Source content is supplied through stdin from a private, temporary file; system
instructions use a private temporary file rather than process arguments. Temporary
files and working directories are removed after completion, failure or cancellation.
The process has a five-minute timeout and is terminated on cancellation, with a
forced kill if it ignores termination. Process/pipe callbacks are bridged to async
streams; waiting for the CLI does not block Swift's cooperative executor.

Built-in tools, MCP servers, skills/commands, hooks and personal/project
customizations are disabled. CLI conversation persistence is disabled. Inherited
Anthropic credentials and Claude routing/configuration overrides are removed from
the subprocess environment. Source documents and image originals are never supplied
to the CLI; the provider advertises text input only. Local Only blocks this cloud
provider before source execution, including preset overrides and hierarchical passes.

Only the StructuredOutput tool's answer field supplies partial Markdown. Final
structured output is required; agent commentary is never saved as an answer.
Transcript and source reference resolvers validate returned IDs against the selected
context. Model-generated numeric locations are discarded. CLI diagnostic output is
not logged or displayed because it can include source content or credentials.

The CLI owns its credentials and token refresh. AudioNotes neither reads nor copies
Claude Code's tokens. Generation metadata records the non-secret `claudeCode`
authentication method and the returned model ID when available. Reported usage,
including cache tokens, is retained; missing usage remains unavailable. CLI cost
figures describe model usage and are not assumed to be the user's charge. Billing
is **unknown**, not automatically classified as included with a subscription.
Anthropic determines whether usage consumes plan allowances or paid credits.

## Desktop build and existing data

The app target disables App Sandbox so the external native CLI can access its own
installation, configuration and Keychain login. Hardened Runtime remains enabled.
This build is intended for direct macOS distribution, not the Mac App Store sandbox.

`AppStorageLocations` reuses an existing sandbox Application Support directory when
its database or AudioNotes managed-storage directory is present. The default
SwiftData store, audio/source originals and downloaded models stay in place.
Known non-secret provider/privacy preferences are restored once without replacing
existing desktop values. No historical summaries, chats or usage records are rewritten.

## Validation

Unit tests cover account gating, CLI login commands, independent model persistence,
Local Only, structured streaming, invalid citations, multi-source prompts, usage
retention, temporary-file cleanup, timeout/cancellation and existing storage/preferences.
A live initialization-only probe returned the signed-in CLI model list.
A live neutral connectivity check succeeded with Claude Code 2.1.286 on this Mac.
Interactive browser login and a full native recording workflow still require manual
acceptance. Older CLIs that do not support the integration's flags must be updated;
AudioNotes does not retry using weaker isolation flags.

Official references checked 2026-10-01:

- [CLI reference](https://code.claude.com/docs/en/cli-reference)
- [Programmatic use and structured output](https://code.claude.com/docs/en/headless)
- [Account authentication and third-party usage](https://support.claude.com/en/articles/13189465-log-in-to-your-claude-account)

- [Official Agent SDK initialization implementation](https://github.com/anthropics/claude-agent-sdk-python/blob/main/src/claude_agent_sdk/_internal/query.py)
