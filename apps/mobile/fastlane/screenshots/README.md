# Store screenshots — plan

Screenshots are rendered on a real device or simulator by
`integration_test/store_screenshots_test.dart`, on the mock backend, so every run shows the
same people, prices and jobs, and the platform's own fonts draw every glyph (the headless test
font has no ₦). The PNGs land in `fastlane/screenshots/<platform>/` and are not committed
until the client approves the brand artwork (RB-15, client action).

## What is shown, in order

| # | Screen | Why it is in the set |
|---|---|---|
| 01 | Customer home | What the app is for, in one glance |
| 02 | Offers board (ranked) | Comparing providers by price and rating is the core decision |
| 03 | Live tracking | Where the provider is |
| 04 | Pay into held funds | Money is held until the job is done — the trust proposition |
| 05 | Chat | Talking to the provider without sharing a number |
| 06 | Wallet | Balances and history |
| 07 | Provider dashboard | The earning side |
| 08 | Provider jobs | Running a job end to end |

Each in dark and light. Captions, if the client wants them, are added in the store consoles
rather than baked into the images, so they can be translated without a rebuild.

## Sizes the stores require

| Store | Device class | Pixels (portrait) | Run on |
|---|---|---|---|
| App Store | iPhone 6.9" (required, or the 6.5" set instead) | 1260 × 2736 [V] | largest iPhone simulator; resize to the listed size if its native size differs |
| App Store | iPhone 6.5" | 1284 × 2778 [V] | only if the 6.9" set is not supplied |
| Google Play | Phone | 16:9 or 9:16, 320–3840 px per side; at least 1080 px for promotion | Pixel 8/9 emulator (1080 × 2400) |

[V] developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications,
read 2026-09-28. The Play row is `VERIFY-IN-RESEARCH`: check Play Console's "Preview assets"
help on the day; both stores revise these tables.

The app is iPhone-only and phone-only (TARGETED_DEVICE_FAMILY = 1; no tablet layouts), so no
iPad or tablet screenshots are needed.

## Commands

```bash
cd apps/mobile
SCREENSHOT_PLATFORM=ios flutter drive --driver=test_driver/screenshot_driver.dart \
  --target=integration_test/store_screenshots_test.dart -d "iPhone 16 Pro Max"
SCREENSHOT_PLATFORM=android flutter drive --driver=test_driver/screenshot_driver.dart \
  --target=integration_test/store_screenshots_test.dart -d emulator-5554
```

Play also needs a 512 × 512 icon and a 1024 × 500 feature graphic. The icon comes from
`tool/brand/generate_icons.py`'s master; the feature graphic is brand artwork and waits for
the client.
