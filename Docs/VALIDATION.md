# Source Validation Record

This record covers source commit `623d5766b0c74b06fc7c82e8c37982a003b27a2a`. Subsequent documentation-only commits add and clarify this record; they do not change the validated source tree.

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
