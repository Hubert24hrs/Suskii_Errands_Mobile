#!/usr/bin/env bash
# Resolves every Dart package and generates the code that is not committed (freezed/json in
# suskii_domain, gen-l10n in suskii_l10n), so `flutter build` works from a clean checkout.
# Used by the native build and release workflows; frontend-ci does the same steps inline.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
for dir in packages/suskii_domain packages/suskii_core packages/suskii_design packages/suskii_l10n packages/suskii_data apps/mobile; do
  (cd "$repo/$dir" && flutter pub get)
done
(cd "$repo/packages/suskii_l10n" && flutter gen-l10n)
(cd "$repo/packages/suskii_domain" && dart run build_runner build)
