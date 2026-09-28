# ADR-0015 — One define file per environment drives the app on both platforms

| | |
|---|---|
| Status | Accepted |
| Date | 2026-09-28 |
| Supersedes | — |
| Related | [RB-15](../runbooks/RB-15-store-release.md), audit [2026-09-27](../audit/AUDIT-2026-09-27.md) Y.10 |

## Context

The app has three environments — dev, staging, prod — and until now only its Dart code knew which
one it was in, through `--dart-define-from-file=config/env/<env>.json`. The native projects knew
nothing: one application id for all three, a template label, and on Android and iOS two
*different* ids (`com.suskiierrands.suskii_mobile` vs `com.suskiierrands.suskiiMobile`), so a
staging build would overwrite production on a tester's phone and the stores would see two apps.

The usual Flutter answer is product flavors on Android and matching Xcode schemes and build
configurations on iOS. That puts the environment in three places (define file, Gradle, Xcode) that
must agree, and the Xcode half is a hand-edited project file with nine build configurations that
nobody in this project can open, because no one here has a Mac.

## Decision

The define file is the one place an environment is described. It gains three keys —
`APP_NAME`, `APP_LINK_HOST` and the existing `APP_FLAVOR` — and both native builds read it:

- **Android**: Flutter passes the defines to Gradle, base64-encoded, in the `dart-defines`
  property. `app/build.gradle.kts` decodes them and sets `applicationIdSuffix` (`.dev`,
  `.staging`, none for prod), the launcher label and the App Links host as manifest placeholders,
  and chooses the network security config (emulator cleartext only in dev).
- **iOS**: `tool/write_ios_defines.sh` writes `ios/Flutter/DartDefines.xcconfig` (gitignored)
  with `APP_ID_SUFFIX`, `APP_DISPLAY_NAME` and `APP_LINK_HOST`; `Environment.xcconfig` holds dev
  defaults and includes it optionally. The Runner scheme's pre-action runs the script from
  `DART_DEFINES` on every build, and the release workflow runs it from the file explicitly.
- One application id everywhere: `com.suskiierrands.app` plus the suffix (ADR-0017).

`flutter build` and `flutter run` need no `--flavor`. Release builds use
`build/env/<env>.json`, the committed file with the backend values merged from secrets by
`tool/write_release_env.sh`, which refuses a staging or prod build without a backend — that build
would be the mock app.

## Consequences

**Good:** one file per environment, readable by anyone; no Xcode surgery; dev, staging and prod
install side by side; adding an environment is adding a JSON file.

**Bad / costs:** Gradle decoding `dart-defines` relies on how the Flutter tool passes defines
today; a Flutter release that changes it breaks the id suffix (the `mobile-native` workflow would
show a prod id on a dev build). The iOS pre-action is invisible to anyone reading only the
project settings, which is why `Environment.xcconfig` says where the values come from.

**Not verified here:** neither native build has been compiled from this change (no Google Maven
access, no macOS in the authoring environment). `mobile-native.yaml` and `mobile-ios.yaml` are
the first compilations; the iOS one also asserts the bundle id and display name of a prod build.

## Alternatives considered

| Option | Why not |
|---|---|
| Product flavors + Xcode schemes | The environment in three places; a nine-configuration pbxproj edited by hand without Xcode |
| Separate apps per environment in the stores | Staging is for internal testers; TestFlight and Play internal testing already separate it from the public |
| A single id for all environments | A staging build would replace the store build on a tester's phone |

## Revisit when

A Mac joins the team and the Flutter tooling for flavors improves, or a Flutter release changes how
defines reach Gradle.
