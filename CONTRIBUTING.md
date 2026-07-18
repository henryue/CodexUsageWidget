# Contributing

Thanks for helping improve Codex Usage Widget.

## Before opening a pull request

1. Keep account data, credentials, raw app-server responses, home-directory paths, signing files, and real usage values out of commits and test fixtures.
2. Preserve the security boundary: the host owns the Codex child process; the sandboxed Widget reads only the sanitized App Group snapshot.
3. Add or update tests for behavior changes.
4. Run the Swift package tests:

   ```sh
   swift test \
     --disable-sandbox \
     --scratch-path /tmp/CodexUsageWidget-SPM
   ```

5. For Xcode or Widget changes, also run the unsigned Release build and Xcode test commands documented in the README.

## Pull requests

- Keep each pull request focused on one change.
- Explain the user-visible effect and the validation performed.
- Do not weaken safety, privacy, accessibility, or stale-data behavior to make a test pass.
- Do not include generated build products, signing identities, provisioning profiles, result bundles, or diagnostics.

By contributing, you agree that your contribution will be licensed under the repository's MIT License.
