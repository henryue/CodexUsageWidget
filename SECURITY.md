# Security Policy

## Supported version

Security fixes are applied to the latest commit on the default branch. This source-only project does not currently publish signed or notarized binary releases.

## Reporting a vulnerability

Please do not disclose a suspected vulnerability in a public issue. Use the repository's **Security** tab and choose **Report a vulnerability** to send a private report. Include the affected commit, macOS version, reproduction steps, impact, and any suggested mitigation.

If private vulnerability reporting is temporarily unavailable, open a public issue that asks the maintainer to provide a private reporting channel, but do not include vulnerability details.

The maintainer will acknowledge a usable report when practical, investigate it, and coordinate disclosure after a fix or mitigation is available. This is a volunteer-maintained project, so no fixed response-time guarantee is offered.

## Security boundaries

- The host app is intentionally unsandboxed because it launches an external Codex executable. It invokes no shell and accepts only a resolved absolute executable path.
- The Widget extension remains sandboxed and reads only the sanitized App Group snapshot.
- The host owns and terminates the app-server child process it starts.
- Neither target should read credential files, browser state, Keychain tokens, or raw account pages.
- Test fixtures, screenshots, logs, and diagnostics must never contain real account data, signing identifiers, credentials, or home-directory paths.

Changes that weaken these boundaries require explicit security review and regression coverage.
