# RB-15 — Releasing the mobile app to Google Play and the App Store

| | |
|---|---|
| Owner | Claude Code (pipeline) / client (store accounts, signing, review answers) |
| Severity | SEV2 when a released build is broken in the field; otherwise a planned procedure |
| Last rehearsed | **not yet** — no store account exists (client action 9), so no build has been signed or uploaded |
| Related | [ADR-0015](../adr/0015-environments-from-the-define-file.md), [ADR-0017](../adr/0017-store-identity-and-release-signing.md), [RB-13](RB-13-kill-switch-and-forced-update.md) (forced update), `.github/workflows/mobile-release.yaml`, `apps/mobile/fastlane/`, audit [2026-09-27](../audit/AUDIT-2026-09-27.md) Y.1 and Y.10, drafts in [`docs/store/`](../store/) |

The user asked for this file as `RB-store-release.md`; it is numbered RB-15 to keep the runbook
index in order.

**What is verified and what is not.** Everything in this runbook that runs on Linux has been run:
Fastlane parses and every option name matches 2.240.1, the workflows pass `actionlint` and
`shellcheck`, the define-file scripts are tested, the App Links files and the account-deletion
page are served and smoke-tested. **The Android and iOS builds themselves have not been compiled
from this change**: the environment it was written in cannot reach Google's Maven repository and
has no macOS. `mobile-native.yaml` (Android release bundle) and `mobile-ios.yaml` (iOS release,
unsigned) are the first place they compile; read their first run before trusting anything below.

## 1. Client actions — nothing ships until these are done

Numbers continue the client action list in [timeline.md §5](../plan/timeline.md). Items marked
**(9)** are that list's action 9, split into what it actually involves.

| # | Action | Needed for | Hand to Claude Code as |
|---|---|---|---|
| 9a | **Google Play Console developer account** for the operating entity (organisation account; D-U-N-S and identity verification) | Any Play upload | Invite to the Console with Release manager |
| 9b | **Apple Developer Program membership** for the entity (organisation; D-U-N-S) | TestFlight, App Store | The 10-character **Team ID** |
| 17 | **Confirm the app identifier `com.suskiierrands.app`** on both stores. It cannot be changed after the first upload (OD-26) | First upload | A yes, or the identifier to use instead |
| 18 | **Choose the domain** (infra I-2). App Links, the privacy and terms URLs, the support email and the store listings all use the placeholder `suskii-errands.example` today | App Links, listings, legal links | The domain; Claude Code replaces the placeholder in `apps/mobile/config/env/*.json` and `fastlane/metadata` |
| 19 | **Brand artwork**: a 1024 × 1024 icon master with no transparency, a 1024 × 500 Play feature graphic, confirmation of the brand colours. Today's icon is an interim mark generated from the design tokens (`tool/brand/generate_icons.py`) | Listing, launcher icon | Files; Claude Code re-runs the generator from the master |
| 20 | **Play: create the app** in Play Console with package `com.suskiierrands.app`, accept **Play App Signing** (Google holds the app signing key), and create the **upload key** (§3.1) | First Android upload | The four `ANDROID_UPLOAD_*` secrets (§3.1) set in the GitHub environment, not sent to anyone |
| 21 | **Play: service account** with release permissions on the app, for the Play Developer API | Automated uploads | `PLAY_SERVICE_ACCOUNT_JSON` secret |
| 22 | **Apple: register the App ID** `com.suskiierrands.app` with **Push Notifications**, **Associated Domains** and **Sign in with Apple** enabled (the app's entitlements ask for all three; a profile without them fails signing), and create the app record in App Store Connect | First iOS upload | — |
| 23 | **App Store Connect API key** (Users and Access → Integrations). Automatic signing with `-allowProvisioningUpdates` creates certificates and profiles, which needs the **Admin** role — `VERIFY-IN-RESEARCH` whether App Manager suffices | Signing and TestFlight | `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (the .p8 contents), `APPLE_TEAM_ID` |
| 24 | **Privacy policy and terms** at the listed URLs, approved by counsel (OD-24, action 16) | Both stores refuse a listing without a privacy policy | Published pages |
| 25 | **A review account**: a phone number with a fixed one-time code in the **production** Supabase Auth settings (Auth → Phone → test OTP), so reviewers can sign in without an SMS | Apple guideline 2.1; Play "App access" | The number and code, entered in App Store Connect's review information and Play's App access — never committed |
| 26 | **Store questionnaires**: Play Data safety and Apple App Privacy (drafts in `docs/store/`), Play content rating (IARC) and target audience, Apple age rating (the updated questions have been mandatory since 31 Jan 2026 [V]), Play's **precise-location declaration** (enforced from 27 Jan 2027 [V] REPORT §10) | Submission | Answers entered in the consoles |
| 27 | **Firebase project** (FCM) and an **APNs key** uploaded to it | Push notifications — not in the app yet (§6) | Firebase config values |
| 28 | Optional: a **Sentry** project | Crash reports from release builds | `SENTRY_DSN` secret (a public client key) |
| 4, 7, 11 | Merchant accounts, identity vendor, LiveKit and telephony — already on the list | Payments, KYC, calls | As listed there |

**The store listing must not promise what the build cannot do.** Payments need action 4, in-app
calls need action 11, the concierge needs Phase 7's service. `fastlane/metadata` describes the
core loop only; re-read it against the build before every submission (Apple 2.3.1, Play's
misleading-claims policy).

## 2. What the build is

| | Android | iOS |
|---|---|---|
| Identifier | `com.suskiierrands.app`; `.dev` / `.staging` suffixes | same |
| Name | `Suskii Errands` (prod), `Suskii Staging`, `Suskii Dev` | same |
| Environment | `--dart-define-from-file=config/env/<env>.json` (ADR-0015); release builds use `build/env/<env>.json` with the backend values merged in by `tool/write_release_env.sh`, which refuses a staging or prod build without a backend | same, plus `tool/write_ios_defines.sh` for the bundle id, name and link host |
| Version | `pubspec.yaml` `version: 1.0.0+N` — the name is semver; the build number comes from the workflow (`run_number × 10`) and only ever goes up | same |
| SDK levels | min 24, target and compile **36** (Play requires 36 for new apps and updates since 31 Aug 2026 [V] developer.android.com/google/play/requirements/target-sdk) | min iOS 15.0; built with **Xcode 26** (required for uploads since 28 Apr 2026 [V] developer.apple.com/news/upcoming-requirements) |
| Shrinking | R8 + resource shrinking; `proguard-rules.pro`; mapping file kept with the build | Dart `--obfuscate` with `--split-debug-info`; symbols kept with the build |
| Devices | phones, portrait | iPhone only (`TARGETED_DEVICE_FAMILY = 1`), portrait |
| Plugins | Gradle | Swift Package Manager (Flutter 3.47's default). There is no Podfile because no plugin needs CocoaPods; if one ever does, `flutter build ios` generates it — set `platform :ios, '15.0'` in it and commit it |

### Permissions, and why each is there

| Permission / key | Platform | Why | When it is asked |
|---|---|---|---|
| `INTERNET` | Android | Everything. Its absence from the main manifest was audit Y.1 (Critical) | Not a runtime permission |
| `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` / `NSLocationWhenInUseUsageDescription` | both | While a provider is on a job: the customer's live map (broadcast on the job's channel, ADR-0009), the trip trail through the heartbeat, and the 150 m pickup geofence when they mark arrival (`set_job_status`, transition 13). Fine, because coarse cannot resolve 150 m. Foreground only; there is no background location (OD-27) | At "Start journey", after an in-app explanation the provider can decline and still travel; never at launch |
| `NSCameraUsageDescription` | iOS | Photographing an ID document, a receipt or proof of a finished job | When the person chooses "Take a photo" |
| `NSPhotoLibraryUsageDescription` | iOS | Choosing such a photo from the library | When the person chooses "Choose from library" |
| — (no CAMERA, no READ_MEDIA_*) | Android | `image_picker` hands off to the system camera and the Android photo picker, which need no permission | — |

Not declared, on purpose: microphone (calls and the voice concierge have no audio yet), notifications
(no push yet), background location, contacts, phone state, foreground services. `mobile-native.yaml`
fails if a plugin adds a sensitive permission or a foreground service type to the merged manifest.
The first compiled build caught one: `geolocator` adds `FOREGROUND_SERVICE_LOCATION` and a
`location`-typed service for tracking with the app closed. The app never starts that service, so the
manifest strips the permission and the type (`tools:node="remove"`, `tools:remove`), which keeps a
foreground-service declaration off the Play listing; the service itself stays because the plugin binds
it to deliver the in-app position stream. OD-27 is where that changes.

### Other store-facing settings

- **Network**: HTTPS only and system CAs only in staging and prod (`res/xml/network_security_config.xml`); dev adds cleartext to the emulator's host loopback for `supabase start`.
- **Backups**: off (`allowBackup=false`, `data_extraction_rules.xml`). The session is in Keystore-backed storage no other device can decrypt; a restored copy would strand the user.
- **Screens with money, identity documents and PINs** block screenshots on Android (`FLAG_SECURE`) and are blurred in the iOS app switcher.
- **Encryption**: `ITSAppUsesNonExemptEncryption = false` — the app uses only the operating system's HTTPS. Revisit if anything adds its own cryptography.
- **Privacy manifest**: `ios/Runner/PrivacyInfo.xcprivacy`. It must match the App Privacy answers.
- **App Links / Universal Links**: `https://<host>/app/<route>` opens `<route>`. The marketing site serves `/.well-known/assetlinks.json` from `ANDROID_CERT_SHA256` (the SHA-256 of Play's app signing key and of the upload key, comma-separated, from Play Console → App integrity) and `/.well-known/apple-app-site-association` from `APPLE_TEAM_ID`. Both are inert until those variables are set.
- **Account deletion**: in the app (Profile → Settings → Delete account), on the web (web-customer settings), and described at `https://<host>/<locale>/delete-account` — the URL Play's Data safety form asks for.

## 3. One-time setup

### 3.1 The Android upload key (client present; the key never leaves their control)

```bash
keytool -genkeypair -v -keystore upload.jks -alias upload -keyalg RSA -keysize 4096 \
  -validity 10000 -storetype PKCS12
base64 -w0 upload.jks   # the value of ANDROID_UPLOAD_KEYSTORE_BASE64
```

Set `ANDROID_UPLOAD_KEYSTORE_BASE64`, `ANDROID_UPLOAD_KEYSTORE_PASSWORD`, `ANDROID_UPLOAD_KEY_ALIAS`
(`upload`) and `ANDROID_UPLOAD_KEY_PASSWORD` as secrets of the GitHub **prod** environment (and
staging, if staging goes to Play). Keep the `.jks` and its passwords in the client's password
manager: with Play App Signing a lost upload key can be reset through Play support, but not quickly.

**Never commit a keystore, a `key.properties`, a `.p8`, a `.p12` or a provisioning profile.** The
`.gitignore` files refuse all of them; gitleaks in `security.yaml` is the second line.

### 3.2 GitHub environments

`dev`, `staging` and `prod` environments (RB-14 creates them for the backend) each carry
`SUPABASE_URL`, `SUPABASE_ANON_KEY`, optionally `SENTRY_DSN`, and the signing and store secrets
above. Give `prod` required reviewers, so a production upload needs a second person.

### 3.3 First upload to Play

Play expects the first bundle of a new app through the Console. `VERIFY-IN-RESEARCH` whether the
Developer API accepts a first upload today. If not: run `mobile-release` with `upload: false`,
download the `android-prod-*` artifact and upload `app-release.aab` to the internal track by hand.
Every later release goes through the workflow.

## 4. Releasing

1. **Version.** Bump `version:` in `apps/mobile/pubspec.yaml` (semver name; leave `+1`, the
   workflow sets the build number). Add `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt`
   if the Play release notes should change, and `metadata/ios/en-US/release_notes.txt`.
2. **Green main.** `frontend-ci`, `mobile-native`, `mobile-ios` and `backend-db` green on the commit.
3. **Staging first.** Actions → `mobile-release` → environment `staging`, platforms `both`,
   track `internal`. Install from the internal track and TestFlight; run the smoke list in §5.
4. **Production.** Tag the commit `mobile-v<version>` (the workflow checks the tag equals
   pubspec's version) or run the workflow with `prod`. Android lands on the chosen track —
   `production` uploads as a **draft**, so a person starts the rollout in Play Console. iOS lands
   in TestFlight; submit for review from App Store Connect.
5. **Roll out gradually.** Play: staged rollout 5% → 20% → 50% → 100%, a day apart, watching
   crash-free sessions and support tickets. App Store: phased release for automatic updates.

**Stop conditions.** Never upload a build whose define file had no backend (the script refuses;
do not work around it). Never commit or paste signing material to get a build through. Never
submit a listing that describes a feature the build does not have.

## 5. Smoke list on a real device, per release

Sign in with the review number · create and publish a request · receive and accept an offer ·
reach checkout (and, once a gateway exists, pay into held funds) · chat · as a provider, start a
job and mark arrived (location prompt appears at that tap, and a refusal still allows a manual
arrival) · open a KYC step and photograph a document · Settings → export data · Settings → delete
account → sign in again → keep the account · an `https://<host>/app/customer/wallet` link opens
the wallet · the app-switcher shows the blur on iOS; a screenshot of the wallet is blocked on
Android.

## 6. Not built yet, and what each needs

| Item | Needs | Then |
|---|---|---|
| Push notifications (FCM, APNs) | Actions 27 and 22 | Add `firebase_messaging`, register the token with `register_device` (the RPC exists; the app does not call it yet), declare `POST_NOTIFICATIONS` and ask for it in context, add `remote-notification` background mode |
| In-app calls and the voice concierge | Action 11 | Add the microphone permission and usage string with the feature, not before |
| Sign in with Google | Supabase provider config | Guideline 4.8 then requires Sign in with Apple; the entitlement is already in place |
| Store screenshots | Action 19, a simulator and an emulator | `fastlane/screenshots/README.md` |
| Crash symbol upload | Action 28 and a Sentry auth token | Upload `build/symbols/*` and `mapping.txt` from the release artifacts |

## 7. A release is broken in the field

1. **Stop the rollout.** Play Console → the release → *Halt rollout*. App Store Connect → *Pause
   phased release* (or remove the version from sale if it is harmful).
2. **Contain.** If the fault is server-reachable, switch the feature off with its flag (RB-13).
3. **Fix forward.** Stores cannot downgrade an installed app: build a new version with a higher
   build number through §4. If users must not stay on the bad build, raise
   `min_supported_app_version` (RB-13) once the fix is live.
4. **Tell people.** SEV2 per RB-01; a status note in the app via remote config if many are affected.

## 8. After a release

- Record the version, build number, tracks and dates in `HANDOFF.md`.
- Keep the release artifacts (bundle, mapping, symbols, ipa, dSYMs) for the life of the version:
  without them a crash report cannot be read.
- Update this runbook where it was wrong, and set *Last rehearsed*.
