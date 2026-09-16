import tempfile
import unittest
from pathlib import Path

import policy_check


def write(root: Path, relative: str, content: str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


class PolicyCheckTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def rules(self):
        return sorted({f.rule for f in policy_check.run(self.root)})

    def test_clean_repository_has_no_findings(self):
        write(self.root, "apps/mobile/pubspec.yaml", "dependencies:\n  geolocator: ^14.0.3\n")
        write(self.root, "packages/suskii_l10n/lib/l10n/app_en.arb", '{"held": "Held by Suskii until the job is done"}')
        write(self.root, "apps/mobile/lib/config.dart", "const publishableKey = 'sb_publishable_abc';\n")
        write(self.root, "apps/mobile/android/app/src/main/AndroidManifest.xml",
              '<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>\n')
        self.assertEqual(policy_check.run(self.root), [])

    def test_banned_package_in_pubspec_and_lock(self):
        write(self.root, "apps/mobile/pubspec.yaml", "dependencies:\n  flutterwave_standard: ^1.1.0\n")
        write(self.root, "apps/mobile/pubspec.lock", '  background_locator_2:\n    dependency: "direct main"\n')
        findings = policy_check.run(self.root)
        self.assertEqual([f.rule for f in findings], ["P1-banned-package", "P1-banned-package"])
        by_path = {f.path: f.line for f in findings}
        self.assertEqual(by_path, {"apps/mobile/pubspec.lock": 1, "apps/mobile/pubspec.yaml": 2})

    def test_package_name_prefix_is_not_a_false_positive(self):
        write(self.root, "apps/mobile/pubspec.yaml", "dependencies:\n  flutterwave_standard_extra_docs: ^1.0.0\n")
        self.assertEqual(policy_check.run(self.root), [])

    def test_escrow_in_arb_copy(self):
        write(self.root, "packages/suskii_l10n/lib/l10n/app_pcm.arb", '{"pay": "We go keep am for Escrow"}')
        self.assertEqual(self.rules(), ["P2-escrow-copy"])

    def test_escrow_in_docs_or_code_comments_is_not_copy(self):
        write(self.root, "docs/adr/0002.md", "Never call it escrow.\n")
        write(self.root, "apps/mobile/lib/money.dart", "// never say escrow in copy\n")
        self.assertEqual(policy_check.run(self.root), [])

    def test_service_role_and_vendor_secrets_in_client_code(self):
        write(self.root, "apps/web-admin/src/supabase.ts", "createClient(url, process.env.SUPABASE_SERVICE_ROLE_KEY)\n")
        # Fake credentials are assembled at runtime so secret scanners do not flag this file.
        write(self.root, "apps/mobile/.env", "FLW=" + "FLWSECK" + "_TEST-abcdef1234567890\n")
        write(self.root, "packages/suskii_data/lib/keys.dart", "const k = '" + "sk_" + "live_abcdefghijklmnop1234';\n")
        rules = [f.rule for f in policy_check.run(self.root)]
        self.assertEqual(rules.count("P3-client-secret"), 3)

    def test_secrets_outside_client_roots_are_left_to_gitleaks(self):
        write(self.root, "supabase/functions/x.ts", "Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')\n")
        self.assertEqual(policy_check.run(self.root), [])

    def test_forbidden_android_permissions(self):
        write(self.root, "apps/mobile/android/app/src/main/AndroidManifest.xml",
              '<uses-permission android:name="android.permission.READ_CONTACTS"/>\n'
              '<uses-permission android:name="android.permission.RECEIVE_SMS"/>\n')
        self.assertEqual([f.rule for f in policy_check.run(self.root)], ["P4-android-permission"] * 2)

    def test_build_and_dependency_directories_are_skipped(self):
        write(self.root, "apps/mobile/build/pubspec.lock", "flutterwave_standard:\n")
        write(self.root, "apps/web/node_modules/x/package.json", '{"name": "flutterwave_standard"}')
        self.assertEqual(policy_check.run(self.root), [])

    def test_annotation_format(self):
        finding = policy_check.Finding("P1-banned-package", "apps/mobile/pubspec.yaml", 3, "msg")
        self.assertEqual(finding.annotation(), "::error file=apps/mobile/pubspec.yaml,line=3,title=P1-banned-package::msg")


if __name__ == "__main__":
    unittest.main()
