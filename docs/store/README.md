# Store declarations — drafts

Drafts of the questionnaires both stores require, written from what the code actually does
(2026-09-28). They are **drafts for the client and counsel to confirm**, not answers: the stores
hold the account holder responsible for them (RB-15, client action 26).

| File | For |
|---|---|
| [play-data-safety.md](play-data-safety.md) | Play Console → App content → Data safety |
| [app-privacy.md](app-privacy.md) | App Store Connect → App Privacy (must agree with `ios/Runner/PrivacyInfo.xcprivacy`) |

When the app starts collecting something new — push tokens, microphone audio, a biometric check
through the identity vendor — these two files, the privacy manifest and the privacy policy change
in the same pull request.
