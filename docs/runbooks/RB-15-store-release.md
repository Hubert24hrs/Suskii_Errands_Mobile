# RB-15 — Releasing the mobile app to Google Play and the App Store

| | |
|---|---|
| Owner | Claude Code (pipeline) / client (store accounts, signing, review answers) |
| Severity | SEV2 when a released build is broken in the field; otherwise a planned procedure |
| Last rehearsed | **Partly, 2026-10-13**: `mobile-release` run #1 built and signed the prod AAB (version code 10) with the upload key, upload off, and the owner reports it is live on Google Play. The Play upload, review and rollout steps have not been run by the pipeline; §3.4 is the procedure for taking over |
| Related | [ADR-0015](../adr/0015-environments-from-the-define-file.md), [ADR-0017](../adr/0017-store-identity-and-release-signing.md), [RB-13](RB-13-kill-switch-and-forced-update.md) (forced update), `.github/workflows/mobile-release.yaml`, `apps/mobile/fastlane/`, audit [2026-09-27](../audit/AUDIT-2026-09-27.md) Y.1 and Y.10, drafts in [`docs/store/`](../store/) |

The user asked for this file as `RB-store-release.md`; it is numbered RB-15 to keep the runbook
index in order.

**What is verified and what is not.** Everything in this runbook that runs on Linux has been run:
Fastlane parses and every option name matches 2.240.1, the workflows pass `actionlint` and
`shellcheck`, the define-file scripts are tested, the App Links files and the account-deletion
page are served and smoke-tested. The environment this was written in cannot reach Google's Maven
repository and has no macOS, so the Android and iOS builds were first compiled by CI:
`mobile-native.yaml` (prod release bundle, dev release APK, merged-manifest permission check) and
`mobile-ios.yaml` (iOS release, unsigned) **both passed on 2026-09-28** (PR #41). The first Android
run found a foreground-service declaration from `geolocator` (audit Y.35), now stripped. What is
still unverified is everything after compiling: signing, upload and review, which need the store
accounts.

## 1. Client actions — nothing ships until these are done

Numbers continue the client action list in [timeline.md §5](../plan/timeline.md). Items marked
**(9)** are that list's action 9, split into what it actually involves.

| # | Action | Needed for | Hand to Claude Code as |
|---|---|---|---|
| 9a | **Google Play Console developer account** for the operating entity (organisation account; D-U-N-S and identity verification) | Any Play upload | Invite to the Console with Release manager |
| 9b | **Apple Developer Program membership** for the entity (organisation; D-U-N-S) | TestFlight, App Store | The 10-character **Team ID** |
| 17 | **Confirm the app identifier `com.suskiierrands.app`** on both stores. It cannot be changed after the first upload (OD-26) | First upload | A yes, or the identifier to use instead |
| 18 | ~~**Choose the domain**~~ **Done 2026-10-24: `suskiierrand.com`**, registered by the owner through Cloudflare Registrar (auto-renew on, expires 2027-10-24), its DNS on Cloudflare's Free plan. Note the spelling: no final "s", unlike the app name and `com.suskiierrands.app`; `suskiierrands.com` was registered on 2026-06-02 at Host Africa (Pty.) Ltd., owner unconfirmed. App Links, the privacy and terms URLs, the support email and the store listings all use the placeholder `suskii-errands.example` today | App Links, listings, legal links | The domain; Claude Code replaces the placeholder in `apps/mobile/config/env/*.json` and `fastlane/metadata` |
| 19 | **Brand artwork**: a 1024 × 1024 icon master with no transparency, a 1024 × 500 Play feature graphic, confirmation of the brand colours. Today's icon is an interim mark generated from the design tokens (`tool/brand/generate_icons.py`) | Listing, launcher icon | Files; Claude Code re-runs the generator from the master |
| 20 | **Play: create the app** in Play Console with package `com.suskiierrands.app`, accept **Play App Signing** (Google holds the app signing key), and create the **upload key** (§3.1) | First Android upload | The four `ANDROID_UPLOAD_*` secrets (§3.1) set in the GitHub environment, not sent to anyone |
| 21 | **Play: service account** with release permissions on the app, for the Play Developer API | Automated uploads | `PLAY_SERVICE_ACCOUNT_JSON` secret |
| 22 | **Apple: register the App ID** `com.suskiierrands.app` with **Push Notifications**, **Associated Domains** and **Sign in with Apple** enabled (the app's entitlements ask for all three; a profile without them fails signing), and create the app record in App Store Connect | First iOS upload | — |
| 23 | **App Store Connect API key** (Users and Access → Integrations). Automatic signing with `-allowProvisioningUpdates` creates certificates and profiles, which needs the **Admin** role — `VERIFY-IN-RESEARCH` whether App Manager suffices | Signing and TestFlight | `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (the .p8 contents), `APPLE_TEAM_ID` |
| 24 | **Privacy policy and terms** at the listed URLs, approved by counsel (OD-24, action 16) | Both stores refuse a listing without a privacy policy | Published pages |
| 25 | **A review account**: a phone number with a fixed one-time code in the **production** Supabase Auth settings (Auth → Phone → test OTP), so reviewers can sign in without an SMS | Apple guideline 2.1; Play "App access" | The number and code, entered in App Store Connect's review information and Play's App access — never committed |
| 26 | **Store questionnaires**: Play Data safety and Apple App Privacy (drafts in `docs/store/`), Play content rating (IARC) and target audience, Apple age rating (the updated questions have been mandatory since 31 Jan 2026 [V]), Play's **precise-location declaration** (enforced from 27 Jan 2027 [V] REPORT §10) | Submission | Answers entered in the consoles |
| 27 | **Firebase project** (FCM) and an **APNs key** uploaded to it | Push notifications — not in the app yet (§6) | Firebase config values |
| 29 | **Google sign-in** (built 2026-10-24, ADR-0021): in Google Cloud, OAuth clients for **web**, **Android** (package `com.suskiierrands.app` with the Play app-signing SHA-1 and the upload-key SHA-1) and **iOS** (bundle id) | The Google button in a real build | The client IDs (public identifiers) into `config/env/<env>.json` as `GOOGLE_WEB_CLIENT_ID`, `GOOGLE_IOS_CLIENT_ID`, `GOOGLE_REVERSED_CLIENT_ID`, and into the deploy environment as `GOOGLE_CLIENT_IDS` (web first) with `GOOGLE_SKIP_NONCE_CHECK=true`; the web client secret as `SUPABASE_AUTH_EXTERNAL_GOOGLE_SECRET` for the website |
| 30 | **Sign in with Apple**: a **Services ID** and a **Sign in with Apple key** in the Apple developer account (the App ID capability is action 22) | The Apple button (iOS and website) | `APPLE_CLIENT_IDS` (bundle id, plus the Services ID for the website) and `SUPABASE_AUTH_EXTERNAL_APPLE_SECRET` in the deploy environment |
| 31 | **Google Maps** (built 2026-10-24, ADR-0022): a Google Cloud project with the **Maps SDK for Android**, **Maps SDK for iOS** and **Maps JavaScript API** enabled and **billing** on; one key per platform, restricted (Android: package + SHA-1s — for the Play build that is the **app signing** key's SHA-1 from Play Console → App integrity, because Play re-signs what users install, plus the upload key's; iOS: bundle id; web: the site's domains) | The pickup map in the app and on the website (without a key both show a "use my location" card instead) | `GOOGLE_MAPS_API_KEY` as a GitHub Actions secret (the app builds read it), `NEXT_PUBLIC_GOOGLE_MAPS_API_KEY` in the website's hosting environment. Never in the repository: the secret scanner fails on a Google key |
| 32 | **Test-APK signing key** (2026-10-24, owner's request): run `apps/mobile/tool/new_test_key.ps1` once on your own computer. It creates a PKCS12 key in `%USERPROFILE%\suskii-test-key` (keep that folder; it is not the Play upload key of action 20) and prints four values and the key's SHA-1 | The `dev-latest` test APK installs over the previous one instead of needing an uninstall, and the Maps key (action 31) can be restricted to the test app: package `com.suskiierrands.app.dev` plus that SHA-1 | Four GitHub Actions secrets: `ANDROID_DEV_KEYSTORE_BASE64`, `ANDROID_DEV_KEYSTORE_PASSWORD`, `ANDROID_DEV_KEY_ALIAS`, `ANDROID_DEV_KEY_PASSWORD`. `mobile-native` uses them for builds of `main` only; until they exist it signs with the runner's throwaway debug key |
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
| Name | `Suskii Errands` (prod and dev: the test APK carries the real name, at the owner's request 2026-10-24), `Suskii Staging` | same |
| Environment | `--dart-define-from-file=config/env/<env>.json` (ADR-0015); release builds use `build/env/<env>.json` with the backend values merged in by `tool/write_release_env.sh`, which refuses a staging or prod build without a backend | same, plus `tool/write_ios_defines.sh` for the bundle id, name and link host |
| Version | `pubspec.yaml` `version: 1.0.0+N` — the name is semver; the build number comes from the workflow: `BUILD_NUMBER_FLOOR + run_number × 10` (the floor is a repository variable, 0 when unset), or the `build_number` input to force one. It only ever goes up | same |
| SDK levels | min 24, target and compile **36** (Play requires 36 for new apps and updates since 31 Aug 2026 [V] developer.android.com/google/play/requirements/target-sdk) | min iOS 15.0; built with **Xcode 26** (required for uploads since 28 Apr 2026 [V] developer.apple.com/news/upcoming-requirements) |
| Shrinking | R8 + resource shrinking; `proguard-rules.pro`; mapping file kept with the build | Dart `--obfuscate` with `--split-debug-info`; symbols kept with the build |
| Devices | phones, portrait | iPhone only (`TARGETED_DEVICE_FAMILY = 1`), portrait |
| Plugins | Gradle | Swift Package Manager (Flutter 3.47's default). There is no Podfile because no plugin needs CocoaPods; if one ever does, `flutter build ios` generates it — set `platform :ios, '15.0'` in it and commit it |

### Permissions, and why each is there

| Permission / key | Platform | Why | When it is asked |
|---|---|---|---|
| `INTERNET` | Android | Everything. Its absence from the main manifest was audit Y.1 (Critical) | Not a runtime permission |
| `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` / `NSLocationWhenInUseUsageDescription` | both | A customer's pickup point ("use my location" on the request form, ADR-0022). An online provider's position every 45 s while the app is open, because matching only considers a fix younger than two minutes (audit AA.1). While a provider is on a job: the customer's live map (broadcast on the job's channel, ADR-0009), the trip trail through the heartbeat, and the 150 m pickup geofence when they mark arrival (`set_job_status`, transition 13). Suskii Meet sorts meet-ups by distance (asked per visit, not stored). Fine, because coarse cannot resolve 150 m. Foreground only; there is no background location (OD-27) | When the person taps "use my location", goes online, starts a journey (after an in-app explanation they can decline and still travel) or opens Suskii Meet; never at launch |
| `NSCameraUsageDescription` | iOS | Photographing an ID document, a receipt or proof of a finished job | When the person chooses "Take a photo" |
| `NSPhotoLibraryUsageDescription` | iOS | Choosing such a photo from the library | When the person chooses "Choose from library" |
| — (no CAMERA, no READ_MEDIA_*) | Android | `image_picker` hands off to the system camera and the Android photo picker, which need no permission | — |

The country a new account is created in is read without any permission: the mobile network the phone is registered on and the SIM's country (Android `TelephonyManager`), or the time zone and region (iOS), then the locale (`lib/app/device_country.dart`, 2026-10-24). It is sent once, as sign-up metadata. The store drafts in `docs/store/` declare it as approximate location; `VERIFY-IN-RESEARCH` whether a country-level inference needs that declaration.

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

### 3.4 The app is already on Play (owner, 2026-10-24)

The owner reports the app is live on Google Play. **What the run history shows [V]**:

- `mobile-release` run #1 (2026-10-13, `main` at `3fbf3ca`, started by the owner) built the
  **prod** App Bundle: package `com.suskiierrands.app`, version code **10**.
- It was signed with the upload key held in the `prod` environment's secrets, with upload off.
  The artifact `android-prod-10` (kept 90 days) was then uploaded to Play by hand, as §3.3
  expects for a first upload.
- Its define-file step passed for `prod`, so the `prod` environment has a `SUPABASE_URL`.
- **No `deploy-production` or `infra-deploy` run exists**, and every `pipeline-main` deploy to dev
  and staging was skipped. Unless migrations were pushed to that project by hand, the build on
  Play calls a database with no schema and cannot load.

Before the workflow uploads anything, confirm four facts in Play Console, and stop if any one does
not match:

1. **Package.** Play Console → the app → Dashboard. It must be `com.suskiierrands.app` (OD-26);
   the prod build has no suffix. If it is anything else, stop and ask the owner: a package name
   cannot change, and building another one means a second listing.
2. **Highest version code.** Test and release → App bundle explorer, across every track. Run #1
   produced 10, and the next run number gives 20, so nothing is needed if 10 is the highest.
   If anything higher was uploaded by hand, set the repository variable `BUILD_NUMBER_FLOOR` to
   that number. The next run then uploads `floor + run × 10`, and Play does not refuse it as a
   duplicate or a downgrade.
3. **The upload key.** Test and release → App integrity → upload key certificate. Its SHA-1 must
   match the keystore behind `ANDROID_UPLOAD_KEYSTORE_BASE64`
   (`keytool -list -v -keystore upload.jks`). If the keystore that made the first upload cannot
   be found, request an upload key reset in the same page and register a new key per §3.1.
4. **What it talks to.** A build made with `config/env/dev.json` runs on demo data. If the build on
   Play was one, every installed copy is a demo until an update ships with a production backend.
   `tool/write_release_env.sh prod` refuses to build without one, so the backend comes first
   (RB-14, then RB-08 for the country).

**Answers, read in Play Console on 2026-10-24 [V]** (public certificate fingerprints only):

| Fact | Answer |
|---|---|
| Package | `com.suskiierrands.app`, the Play app "Suskii Errands" on the personal developer account Hubert.dev (closed test of 12 testers × 14 days needed before production) |
| Tracks | **Internal testing only**; nothing on production, so "live on Play" means the internal track |
| Highest version code | **10** (1.0.0), the only bundle ever uploaded; `BUILD_NUMBER_FLOOR` is not needed |
| Play App Signing | On. App signing key SHA-256 `43:10:2F:32:2B:BF:FB:B5:6C:86:1B:9C:F6:B6:DB:0A:E7:7A:B0:CD:2E:0A:F2:05:28:AC:F9:58:53:5E:DD:98`, SHA-1 `57:FF:13:32:15:D6:B5:82:90:2D:5E:F4:44:DA:90:92:8B:E2:ED:37` (read from `deployment_cert.der`, Download certificates on the App signing page, whose SHA-256 matches). These two and the upload key's SHA-1 are what the Maps Android key and the Google sign-in Android client must list |
| Upload key | Created 2026-10-13 on the owner's PC (`C:\Users\HP\suskii-signing\upload.jks`, not in git); `CN=Suskii Errands, O=Suskii Errands, C=NG`, SHA-1 `1A:8F:D5:25:30:C3:5A:6B:6B:68:41:FD:A7:85:B8:D4:C5:D0:87:D7`, SHA-256 `1E:F8:10:8D:52:5C:A1:F7:4C:DB:6D:92:32:02:D6:35:3B:08:B4:7A:80:F3:98:E6:2F:0E:FE:A6:75:43:83:85` (read from the signed bundle of run #1). The four `ANDROID_UPLOAD_*` secrets in `prod` hold this key |
| Play Developer API | Service account `play-publisher@suskii-prod.iam.gserviceaccount.com`, release and store-presence permissions on this app only; its key is `PLAY_SERVICE_ACCOUNT_JSON` in `prod` |
| Backend behind the build | `prod` project ref `slfbtdwzoijgzqszfufp` (Supabase Free, London). **Not empty**: on 2026-10-13 the owner chose to use it as a test sandbox, so the 70 migrations up to `20261013120200` were pushed by hand (`supabase db push`, outside RB-14), **the dev seed was loaded**, and Auth was set in the dashboard (the two Postgres hooks, email OTP of 6 digits through the owner's Gmail SMTP, templates showing the code). The eight migrations from `20261013120300` are not applied. Internal testers have signed in to it. It must be wiped or recreated before production is deployed through RB-14, because production is built from migrations only. **Decided 2026-10-25 (owner, on Claude Code's recommendation): keep it as the testers' sandbox until launch, then recreate it as a new project.** Wiping it now would only break the internal build: production starts with every country disabled, and none can go live before a payment gateway exists (RB-08). A new project at launch carries no sandbox history and lets RB-16 take its preferred path, with the KEK created before the first push. The new ref means new `SUPABASE_URL` and `SUPABASE_ANON_KEY` values in `prod` and a new build, which launch needs anyway. **Until then, do not run `deploy-production` against it.** Its config push sets Auth from `config.toml`, which has neither the SMTP server nor the code-showing templates that testers' sign-in depends on, and the push may reset them. That is not verified either way; do not find out on this project |

The whole sequence, from those checks to an AAB on the internal track, is written as a prompt for
an agent with the owner's credentials: [`docs/prompts/PLAY-UPDATE-AND-GO-LIVE.md`](../prompts/PLAY-UPDATE-AND-GO-LIVE.md).

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

**Before a store build exists**, the demo app installs from a fixed link that `mobile-native`
republishes after every build of `main`:
`https://github.com/Hubert24hrs/Suskii_Errands_Mobile/releases/download/dev-latest/suskii-dev.apk`.
It is the `dev-latest` pre-release, published at the owner's request (2026-09-30). Because the
repository is public, anyone with the link can install it. That is acceptable only because the
dev build carries no backend address and no key. It runs on demo data, and any 6-digit code
signs in. Android asks to allow the install, because it is not from a store. It is signed with
the fixed test key of action 32 once those secrets exist; before that, with the throwaway debug key
of whichever runner built it, which changes every build, so Android refuses to install a new one
over the old one ("app not installed") until the old one is uninstalled. With the test key, each
new APK installs over the last; the one switch from the debug key to the test key needs a last
uninstall. If `dev.json` ever gains a backend, decide again whether this link should stay public.

## 6. Not built yet, and what each needs

| Item | Needs | Then |
|---|---|---|
| Push notifications (FCM, APNs) | Actions 27 and 22 | Add `firebase_messaging`, register the token with `register_device` (the RPC exists; the app does not call it yet), declare `POST_NOTIFICATIONS` and ask for it in context, add `remote-notification` background mode |
| In-app calls and the voice concierge | Action 11 | Add the microphone permission and usage string with the feature, not before |
| Sign in with Google and Apple | **Built** 2026-10-24; needs actions 29 and 30 | Until then the Google button says it is not set up; Apple appears on iOS only |
| Store screenshots (retake: the brand changed 2026-10-24, ADR-0019) | Action 19, a simulator and an emulator | `fastlane/screenshots/README.md` |
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
