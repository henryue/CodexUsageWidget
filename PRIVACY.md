# Privacy

Codex Usage Widget is designed to expose only the minimum local data needed to render a usage widget.

## Data the app stores

The host app reduces the local Codex app-server response to one versioned snapshot containing only:

- remaining-usage percentages;
- reset dates and window-duration labels;
- snapshot timestamps; and
- connection, freshness, pause, sign-in, or error status.

The snapshot is stored in the App Group shared by the signed host app and Widget extension. The app does not maintain a usage-history database.

## Data the app does not persist

The host transiently receives and parses raw JSON lines from the local Codex app-server in memory. The project does not persist, log, or export that raw JSON. It does not directly read or store account IDs, email addresses, API keys, authentication tokens, browser cookies, Keychain credentials, or `~/.codex/auth.json`. Sanitized diagnostics omit home-directory paths, live percentages, raw protocol messages, and account identifiers.

## Local diagnostic logs

The host and Widget write limited diagnostics to macOS's local unified log through OSLog. These record successful snapshot publication, refresh failure, Widget reload requests, whether a reload was requested by a user action or activation, whether the Widget could read a snapshot, and that snapshot's age in seconds. They do not include account identifiers, credentials, usage values, executable paths, or raw protocol responses. These messages are local diagnostics; the project does not transmit them to a telemetry service.

## Network and process behavior

The sandboxed Widget extension does not make network requests and does not launch Codex. The host app launches the already-installed Codex executable with fixed arguments and reads usage through its local app-server. That Codex process may use the account's existing sign-in to communicate with OpenAI; this project does not intercept or replace that authentication.

## Telemetry

Codex Usage Widget contains no analytics, advertising, crash-reporting SDK, or project-operated telemetry endpoint.

## Removing local data

Turn off **Launch at Login**, quit the app, remove the Widget, and delete the app. The shared snapshot may remain in macOS's App Group container until the system removes it or the user deletes that container manually. Uninstalling does not alter ChatGPT, Codex, or their sign-in state.
