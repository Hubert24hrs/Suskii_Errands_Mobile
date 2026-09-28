## Unreleased (2026-09-28)

- `JobProgressRepository.requestStatusChange` takes `location` and `reasonCode`: arrival needs a
  position inside the pickup geofence or a manual reason (audit Y.29).
- `TrackingRepository.publishProviderLocation` and the `LiveFix` value (ADR-0009, audit Y.31).
- `MediaUploadRepository` and `UploadBucket` (audit Y.5, Y.6); account deletion and export on
  `SettingsRepository`; `UserRepository.updateDisplayName`; `AppBootstrap.accountDeletionScheduledFor`;
  `BootstrapRepository.getBootstrap({countryCode})`.

## 1.0.0

- Initial version.
