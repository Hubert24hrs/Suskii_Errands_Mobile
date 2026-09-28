# ADR-0017 — Store identity, signing and the release pipeline

| | |
|---|---|
| Status | Accepted (the application id awaits the client's confirmation, OD-26) |
| Date | 2026-09-28 |
| Supersedes | — |
| Related | [RB-15](../runbooks/RB-15-store-release.md), [ADR-0015](0015-environments-from-the-define-file.md) |

## Context

The app has never been signed, uploaded or reviewed. Once it is, some choices cannot be undone —
the application id above all — and every release thereafter needs signing material that must never
enter the repository. The client owns the store accounts; Claude Code owns the pipeline.

## Decision

1. **One application id on both stores: `com.suskiierrands.app`**, with `.dev` and `.staging`
   suffixes for the other environments. Underscores are not allowed in iOS bundle ids, so neither
   of the old ids could be shared. Permanent after the first upload, so the client confirms it
   (OD-26) before that upload.
2. **Android**: Play App Signing (Google holds the app signing key); we hold only an upload key.
   The release build reads `android/key.properties`, which the workflow writes outside the checkout
   from four secrets; without it a release build is debug-signed, which Play refuses. R8 and
   resource shrinking on; the mapping file is kept with each release.
3. **iOS**: Xcode automatic signing driven by an **App Store Connect API key**
   (`-allowProvisioningUpdates -authenticationKey…`). No distribution certificate or provisioning
   profile is exported, stored as a secret or committed; the key is the only credential.
4. **Fastlane** (2.240.1, locked) for build, upload and listing metadata;
   **GitHub Actions** (`mobile-release.yaml`) runs it per GitHub environment, manually or on a
   `mobile-v<semver>` tag checked against `pubspec.yaml`. Build numbers derive from the run number
   and only increase. Production Play uploads are drafts: a person starts the rollout.
5. **Compile checks on every change**: `mobile-native.yaml` builds the release AAB and APK and fails
   if a plugin adds a sensitive permission; `mobile-ios.yaml` builds the unsigned iOS release on iOS
   or plugin changes and weekly (macOS minutes cost ten times Linux ones).
6. Minimum permissions, asked at the moment of use; no microphone, notification or background
   location permission until the feature that needs it exists (RB-15 §2).

## Consequences

**Good:** the repository never holds a key; losing a CI runner loses nothing; a release is one
button with a second approver on `prod`; the store listing text lives in the repository next to
the code it describes.

**Bad / costs:** automatic signing needs an API key with a role able to create certificates
(`VERIFY-IN-RESEARCH`: Admin vs App Manager). The first Play upload may have to be manual.
Nothing here has run against a real store account yet (client action 9).

## Alternatives considered

| Option | Why not |
|---|---|
| fastlane match (certificates in a private git repo) | A second repository of signing material to protect, for no gain over API-key automatic signing |
| Certificates and profiles as base64 secrets | Expire yearly and must be rotated by hand; the API key does not |
| Keep the two existing ids | They differ, and `suskii_mobile` cannot be an iOS bundle id |
