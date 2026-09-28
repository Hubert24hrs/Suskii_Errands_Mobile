# App Store — App Privacy (draft)

Answers derived from the code on 2026-09-28. Status: **draft, for the client and counsel**. They
must match `apps/mobile/ios/Runner/PrivacyInfo.xcprivacy`, which lists the same types.

**Tracking:** No. The app does not link data with third-party data for advertising, does not
share it with data brokers, and has no advertising SDK. `NSPrivacyTracking` is false and there are
no tracking domains.

## Data linked to the user

| App Store category → type | Used for | Privacy manifest key |
|---|---|---|
| Contact Info → Name | App Functionality | `NSPrivacyCollectedDataTypeName` |
| Contact Info → Email Address | App Functionality | `NSPrivacyCollectedDataTypeEmailAddress` |
| Contact Info → Phone Number | App Functionality | `NSPrivacyCollectedDataTypePhoneNumber` |
| Contact Info → Physical Address | App Functionality | `NSPrivacyCollectedDataTypePhysicalAddress` |
| Location → Precise Location | App Functionality | `NSPrivacyCollectedDataTypePreciseLocation` |
| User Content → Photos or Videos | App Functionality | `NSPrivacyCollectedDataTypePhotosorVideos` |
| User Content → Customer Support | App Functionality | `NSPrivacyCollectedDataTypeCustomerSupport` |
| User Content → Other User Content | App Functionality | `NSPrivacyCollectedDataTypeOtherUserContent` |
| Identifiers → User ID | App Functionality | `NSPrivacyCollectedDataTypeUserID` |
| Financial Info → Other Financial Info | App Functionality | `NSPrivacyCollectedDataTypeOtherFinancialInfo` |
| Purchases → Purchase History | App Functionality | `NSPrivacyCollectedDataTypePurchaseHistory` |
| Other Data → Other Data Types (government ID number) | App Functionality | `NSPrivacyCollectedDataTypeOtherDataTypes` |

"Fraud prevention and security" is not one of App Store Connect's purposes in the same way as on
Play; identity and location checks are reported under App Functionality. `VERIFY-IN-RESEARCH`
against App Store Connect's purpose list on the day.

## Data not linked to the user

| Category → type | Used for | Note |
|---|---|---|
| Diagnostics → Crash Data | App Functionality | Sentry, only when a DSN is configured; events carry no user and no request bodies (`crash_reporting.dart`) |

## Not collected

Health, fitness, contacts, browsing and search history, audio, sensitive info (as Apple defines
it), device identifiers, advertising data. **When the identity vendor's selfie check ships**, add
biometric processing to the policy and re-answer this (Apple treats face data as sensitive).

## Required reason APIs

The app's own code reads `UserDefaults` through `shared_preferences` (reason `CA92.1`, its own
data). Each plugin ships its own privacy manifest for the APIs it uses.
