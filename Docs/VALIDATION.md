# Source Validation Record

## Maintenance validation — 2026-11-14

This maintenance corrects a test synchronization race; production app and Widget
code are unchanged. The initial Swift Package run reported one failure because
the initialization-timeout test asserted transport cleanup immediately after the
request failed. Timeout delivery and cleanup can complete in separate tasks.
The test now triggers a controlled timeout after initialization starts and waits
for natural cleanup before shutdown. It still requires exactly one stop and no
active transports, including for malformed initialization responses.

Environment: macOS 27.2 (26B123), Xcode 27.2 (27B52), Apple Swift 6.4.2,
Apple Silicon. Final source and build inputs were verified against the isolated
temporary build copy.

Passed checks after the test repair:

- Swift Package tests: 61 runtime tests and 83 core tests, 144 total, zero failures.
- Xcode tests: 144 tests, zero failures.
- Repaired initialization cleanup test: 10 consecutive focused runs passed.
- Unsigned Release build: host and Widget contain `x86_64` and `arm64` slices.
- Live app-server smoke: initialization/read, sanitized snapshot round-trip,
  Small/Medium entry selection, and owned child-process cleanup passed.
- Installed 1.0.1 (build 2) continued publishing available snapshots about every
  32 seconds. The Widget read snapshots aged 0–1 seconds, and system logs
  confirmed successful timeline reloads.
- Strict installed-signature verification passed; only the permanent installed
  Widget extension was registered. No app replacement or restart was needed.

The [current app-server contract](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt)
still supports the implemented rate-limit read and update flow. No compatibility
repair was indicated by the source review or live smoke check. This run did not
force a network outage or sleep, measure desktop pixel redraw latency, or validate
notarization and clean-machine installation. An outdated iOS simulator warning
did not prevent the macOS build or tests from succeeding.

## Maintenance validation — 2026-10-25

The source tree published with this record includes the previously installed
1.0.1 (build 2) changes: current Codex executable discovery, the dashboard and
menu-bar lifecycle, 30-second polling, recovery after transient failures, and
Widget reload coordination. These existing changes were reviewed and freshly
validated for publication; no new runtime repair was required during this check.

Environment: macOS 27.0.1 (26A434), Xcode 27.1 (27A9275), Apple Swift 6.4,
Apple Silicon. Build and test inputs were copied by content to an isolated
temporary directory; all 24 source and build-configuration files were verified
against the final working tree.

Passed checks:

- Swift Package tests: 61 runtime tests and 83 core tests, 144 total, zero failures.
- Xcode tests: 144 tests, zero failures.
- Unsigned Release build: both host and Widget contain `x86_64` and `arm64` slices.
- Live local app-server smoke: initialization and rate-limit read, sanitized
  snapshot round-trip, Small/Medium entry selection, and owned child-process
  cleanup all passed. No account values or raw responses were written to the report.
- Installed host remained in background/accessory mode while successful
  snapshots were observed about every 32 seconds. The Widget read fresh shared
  snapshots and system logs confirmed successful timeline reloads.
- Existing installed host and extension passed strict signature verification.
  Only the extension in the permanent Applications installation was registered;
  the running installation was not replaced or restarted for this check.
- The publication diff was checked for private account data, credentials,
  signing identities, personal home-directory paths, and generated artifacts.

The test and build commands are documented in the [README](../README.md).
Tests cover retry, recovery, cancellation and refresh-policy behavior. This run
did not deliberately disconnect networking, put the Mac to sleep, or measure
continuous desktop pixel refresh latency. WidgetKit still controls redraw timing.
This validation does not establish a signed downloadable release, notarization,
Gatekeeper acceptance, or compatibility on a clean machine.

## Historical validation — 2026-07-18

The following historical checks cover source commit
`623d5766b0c74b06fc7c82e8c37982a003b27a2a`, not later runtime changes.

Validation date: 2026-07-18

Environment:

- macOS 26.5.2 (25F84)
- Xcode 26.6 (17F113)
- Apple Swift 6.3.3
- Apple Silicon validation host

## Passed checks

### Swift package suite

```sh
swift test \
  --disable-sandbox \
  --scratch-path /private/tmp/CodexUsageOpenSourceSPM-Final
```

Result: 133 tests executed, 0 failures, 0 unexpected failures.

### Unsigned universal Release build

```sh
CUW_RELEASE_DIR="$(mktemp -d /private/tmp/CodexUsagePublicRootRelease.XXXXXX)"

xcodebuild clean build \
  -project CodexUsageWidget.xcodeproj \
  -scheme CodexUsage \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$CUW_RELEASE_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  ONLY_ACTIVE_ARCH=NO \
  'ARCHS=arm64 x86_64'
```

Result:

- Host executable: `x86_64 arm64`
- Widget executable: `x86_64 arm64`
- `AppIcon.icns`: present
- `Assets.car`: present

### Public-source checks

- English and Simplified Chinese README local links resolve.
- The two README files use one ordinary reciprocal language link at the top; there is no locale-detection script.
- Preview images contain synthetic data.
- The public commit chain contains no real Apple Team ID, real user home-directory path, credential, private key, or live-looking development timestamp found by the release scan. Synthetic paths such as `/Users/example/...` remain in tests.

## Release boundary

This is source validation, not a signed binary release. No downloadable build is claimed to have Developer ID signing, Hardened Runtime validation, notarization, stapling, Gatekeeper acceptance, or clean-machine installation testing.
