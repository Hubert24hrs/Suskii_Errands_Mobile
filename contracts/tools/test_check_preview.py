import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import check_preview

# The two enum-drift tests that used to live here moved to test_generate_v1.py
# when enums.json moved to generate_v1.py.


def write(root: Path, relative: str, content: str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


MIGRATION = """
-- comment mentioning ERR_NOT_A_REAL_CODE_IN_A_COMMENT is still source text
CREATE TYPE public.user_mode AS ENUM ('customer', 'provider');
CREATE FUNCTION public.f() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'ERR_PROVIDER_NOT_VERIFIED' USING ERRCODE = 'P0001';
END $$;
"""


class CheckPreviewTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        write(self.root, "supabase/migrations/1_init.sql", MIGRATION.replace(
            "-- comment mentioning ERR_NOT_A_REAL_CODE_IN_A_COMMENT is still source text\n", ""))
        write(self.root, "supabase/functions/fn/handler.ts", 'return errorResponse(500, "ERR_INTERNAL");\n')
        write(self.root, "supabase/functions/fn/handler_test.ts", 'assert("ERR_ONLY_IN_TESTS");\n')
        self.catalogue([
            {"code": "ERR_PROVIDER_NOT_VERIFIED", "status": "implemented"},
            {"code": "ERR_INTERNAL", "status": "implemented"},
            {"code": "ERR_OFFER_EXPIRED", "status": "planned"},
            {"code": "ERR_NETWORK", "status": "client"},
        ])

    def tearDown(self):
        self._tmp.cleanup()

    def catalogue(self, codes):
        write(self.root, "contracts/v1/error-codes/codes.json", json.dumps({"codes": codes}))

    def errors(self):
        return [f.message for f in check_preview.check(self.root) if f.level == "error"]

    def test_consistent_repository_passes(self):
        self.assertEqual(self.errors(), [])

    def test_a_new_backend_code_must_be_catalogued(self):
        write(self.root, "supabase/functions/fn/other.ts", 'errorResponse(400, "ERR_BRAND_NEW");\n')
        self.assertEqual(self.errors(), ["ERR_BRAND_NEW is raised but missing from error-codes.json"])

    def test_a_raised_code_marked_planned_must_become_implemented(self):
        write(self.root, "supabase/functions/fn/other.ts", 'errorResponse(400, "ERR_OFFER_EXPIRED");\n')
        self.assertIn("ERR_OFFER_EXPIRED is raised but marked planned; mark it implemented", self.errors())

    def test_an_implemented_code_nobody_raises_is_stale(self):
        (self.root / "supabase/functions/fn/handler.ts").write_text("return ok;\n", encoding="utf-8")
        self.assertEqual(self.errors(), ["ERR_INTERNAL is marked implemented but no backend code raises it"])

    def test_codes_only_in_tests_do_not_count(self):
        self.assertNotIn("ERR_ONLY_IN_TESTS", " ".join(self.errors()))



    def test_malformed_and_duplicate_catalogue_entries(self):
        self.catalogue([
            {"code": "ERR_PROVIDER_NOT_VERIFIED", "status": "implemented"},
            {"code": "ERR_INTERNAL", "status": "implemented"},
            {"code": "ERR_INTERNAL", "status": "implemented"},
            {"code": "err_lower", "status": "maybe"},
        ])
        errors = self.errors()
        self.assertIn("duplicate code ERR_INTERNAL", errors)
        self.assertIn("malformed code name 'err_lower'", errors)
        self.assertIn("err_lower: unknown status 'maybe'", errors)

    def test_unknown_app_codes_are_warnings_not_errors(self):
        write(self.root, "packages/suskii_core/lib/src/errors.dart",
              "static const String a = 'ERR_NETWORK';\nstatic const String b = 'ERR_APP_ONLY';\n")
        findings = check_preview.check(self.root)
        warnings = [f.message for f in findings if f.level == "warning"]
        self.assertEqual(len(warnings), 1)
        self.assertIn("ERR_APP_ONLY", warnings[0])
        self.assertEqual(self.errors(), [])


ARB_EN = "packages/suskii_l10n/lib/l10n/app_en.arb"
ARB_PCM = "packages/suskii_l10n/lib/l10n/app_pcm.arb"


class MeetCopyRulesTest(unittest.TestCase):
    """docs/store/meet-copy-rules.md: Meet copy never reads as paying for attention or company."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        write(self.root, "contracts/v1/error-codes/codes.json", json.dumps({"codes": []}))
        self.arb(ARB_EN, {"meetTitle": "Suskii Meet", "@meetTitle": {"description": "Tab title"}})

    def tearDown(self):
        self._tmp.cleanup()

    def arb(self, relative, entries):
        write(self.root, relative, json.dumps({"@@locale": "en", **entries}))

    def messages(self):
        return [f"{f.file}: {f.message}" for f in check_preview.meet_copy_findings(self.root)]

    def flagged(self):
        return [f.message.split()[2] for f in check_preview.meet_copy_findings(self.root)]

    def test_clean_meet_copy_passes(self):
        self.assertEqual(self.messages(), [])

    def test_a_forbidden_term_in_a_meet_string_fails_ci(self):
        self.arb(ARB_EN, {"meetGiftBody": "Gifts go straight to their wallet"})
        errors = [f.message for f in check_preview.check(self.root) if f.level == "error"]
        self.assertEqual(errors, ["Meet copy: meetGiftBody says 'wallet', which docs/store/meet-copy-rules.md forbids"])

    def test_every_locale_is_read_and_the_key_counts_as_copy(self):
        self.arb(ARB_PCM, {"meetCashOut": "Collect am"})
        self.assertEqual(self.messages(), [
            f"{ARB_PCM}: Meet copy: meetCashOut says 'Cash Out', which docs/store/meet-copy-rules.md forbids",
        ])

    def test_endings_count_and_word_boundaries_hold(self):
        self.arb(ARB_EN, {
            "meetA": "No withdrawals, nothing earned, no sponsorship, no get-paid chats",
            "meetTopicLearning": "Learning",
            "meetTopicFood": "Cashew and suya",
        })
        terms = [m.split(" says ")[1].split(",")[0] for m in self.messages()]
        self.assertEqual(terms, ["'withdrawals'", "'earned'", "'sponsorship'", "'get-paid'"])

    def test_only_meet_keys_are_meet_copy(self):
        self.arb(ARB_EN, {
            "paymentCashHint": "Pay the provider in cash",  # errands, direct payment: not Meet
            "meetingPointLabel": "Cash point",
            "errMeetupFull": "Send cash to join",
            "notifMeetGiftTitle": "Your allowance arrived",
            "@meetTitle": {"description": "Never say wallet here"},
        })
        self.assertEqual(self.flagged(), ["errMeetupFull", "notifMeetGiftTitle"])

    def test_the_website_dictionaries_are_read_without_their_comments(self):
        write(self.root, "apps/web-customer/src/lib/i18n/meet.en.ts",
              "// Copy rules: never say wallet.\n"
              "/* nor\n   sponsor */\n"
              "export const meetEn = {\n"
              "  storeLink: 'https://play.google.com/store',\n"
              "  giftBody: 'A gift for your sugar',\n"
              "} satisfies MeetDictionary;\n")
        self.assertEqual(self.messages(), [
            "apps/web-customer/src/lib/i18n/meet.en.ts: Meet copy: line 6 says 'sugar', which "
            "docs/store/meet-copy-rules.md forbids",
        ])

    def test_web_marketing_meet_pages_are_read_and_its_legal_pages_are_not(self):
        marketing = "apps/web-marketing/src"
        write(self.root, f"{marketing}/app/[locale]/meet/page.tsx", "<p>Earn while you chat</p>\n")
        write(self.root, f"{marketing}/app/[locale]/legal/meet-terms/page.tsx", "<p>No cash value</p>\n")
        write(self.root, f"{marketing}/content/meet-terms.ts", "export const t = 'Cowries cannot be withdrawn';\n")
        write(self.root, f"{marketing}/app/[locale]/page.tsx", "<p>Pay cash on delivery</p>\n")
        self.assertEqual(self.messages(), [
            f"{marketing}/app/[locale]/meet/page.tsx: Meet copy: line 1 says 'Earn', which "
            "docs/store/meet-copy-rules.md forbids",
        ])

    def test_an_exemption_names_one_key_and_carries_a_reason(self):
        self.arb(ARB_EN, {"meetCowriesNoCashValue": "Cowries have no cash value", "meetB": "Cash only"})
        with mock.patch.dict(check_preview.MEET_COPY_EXEMPT,
                             {f"{ARB_EN}#meetCowriesNoCashValue": "the store's no-cash-value disclosure"}):
            flagged = self.flagged()
        self.assertEqual(flagged, ["meetB"])
        for where, reason in check_preview.MEET_COPY_EXEMPT.items():
            with self.subTest(where=where):
                self.assertTrue(reason.strip())


if __name__ == "__main__":
    unittest.main()
