import itertools
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
MARKETING = "apps/web-marketing/src"
RULES = Path(__file__).resolve().parents[2] / "docs" / "store" / "meet-copy-rules.md"


def forbidden_terms_in(document: str) -> set[str]:
    """The first column of the first table under "## Forbidden terms", with cells such as
    "earn, earnings" split into their terms."""
    lines = document.split("## Forbidden terms", 1)[1].splitlines()
    first = next(i for i, line in enumerate(lines) if line.startswith("|"))
    table = list(itertools.takewhile(lambda line: line.startswith("|"), lines[first:]))
    return {term for row in table[2:] for term in row.split("|")[1].strip().split(", ")}


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

    def terms(self):
        return [m.split(" says ")[1].split(", which")[0] for m in self.messages()]

    def exempting(self, entries):
        return mock.patch.dict(check_preview.MEET_COPY_EXEMPT, entries)

    @unittest.skipUnless(RULES.exists(), "docs/store/meet-copy-rules.md arrives with Meet v5 M0-PR1")
    def test_the_terms_are_exactly_the_rules_documents(self):
        self.assertEqual(forbidden_terms_in(RULES.read_text(encoding="utf-8")),
                         set(check_preview.MEET_COPY_TERMS))

    def test_the_rules_document_is_read_from_its_first_table_only(self):
        document = (
            "## Forbidden terms\n\n| Term | Why |\n|---|---|\n| wallet | x |\n| earn, earnings | y |\n"
            "| gifts for dates | z |\n\nThe CI grep enforces exactly this list.\n\n"
            "| Instead of | Say |\n|---|---|\n| send money, tip | Send a gift |\n\n## Rules\n\n| a | b |\n"
        )
        self.assertEqual(forbidden_terms_in(document), {"wallet", "earn", "earnings", "gifts for dates"})

    def test_clean_meet_copy_passes(self):
        self.assertEqual(self.messages(), [])

    def test_a_forbidden_term_in_a_meet_string_fails_ci(self):
        self.arb(ARB_EN, {"meetGiftBody": "Gifts go straight to their wallet"})
        errors = [f.message for f in check_preview.check(self.root) if f.level == "error"]
        self.assertEqual(errors, ["Meet copy: meetGiftBody says 'wallet', which docs/store/meet-copy-rules.md forbids"])

    def test_every_locale_is_read_and_the_key_counts_as_copy(self):
        self.arb(ARB_PCM, {"meetCashOut": "Collect am", "meetCowrieCashout": "Collect am"})
        self.assertEqual(self.messages(), [
            f"{ARB_PCM}: Meet copy: meetCashOut says 'Cash Out', which docs/store/meet-copy-rules.md forbids",
            f"{ARB_PCM}: Meet copy: meetCowrieCashout says 'Cashout', which docs/store/meet-copy-rules.md forbids",
        ])

    def test_endings_count_and_word_boundaries_hold(self):
        self.arb(ARB_EN, {
            "meetA": "No withdrawals, nothing earned, no sponsorship, no get-paid chats",
            "meetLeaderboard": "Top earners this week",
            "meetTopicLearning": "Learning",
            "meetTopicFood": "Cashew and suya",
        })
        self.assertEqual(self.terms(), ["'withdrawals'", "'earned'", "'sponsorship'", "'get-paid'", "'earners'"])

    def test_every_form_of_a_term_is_caught(self):
        # "in any form (... plurals and verb forms included)"
        for text, term in [
            ("Top earners", "earners"), ("withdrawable", "withdrawable"), ("withdrawn", "withdrawn"),
            ("withdrew", "withdrew"), ("cashout", "cashout"), ("Cash-out", "Cash-out"),
            ("getting paid", "getting paid"), ("got paid", "got paid"), ("gets paid", "gets paid"),
            ("gotten paid", "gotten paid"), ("getpaid", "getpaid"), ("pay-to-chat", "pay-to-chat"),
            ("a discreet affair", "discreet affair"), ("discreet affairs", "discreet affairs"),
            ("gift for dates", "gift for dates"), ("gifts for date", "gifts for date"),
            ("generosity", "generosity"), ("generously", "generously"),
            ("earnest", None), ("Learning", None), ("yearning", None), ("cashew", None), ("cashier", None),
        ]:
            with self.subTest(text=text):
                found = check_preview.MEET_COPY.search(text)
                self.assertEqual(found.group(0) if found else None, term)

    def test_every_listed_form_belongs_to_a_term(self):
        words = {w for t in check_preview.MEET_COPY_TERMS for w in t.split()}
        self.assertLessEqual(set(check_preview.MEET_COPY_FORMS), words)

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

    def test_web_marketing_meet_pages_are_read_legal_pages_included(self):
        write(self.root, f"{MARKETING}/app/[locale]/meet/page.tsx", "<p>Earn while you chat</p>\n")
        write(self.root, f"{MARKETING}/app/[locale]/legal/meet-guidelines/page.tsx",
              "<p>Earn Cowries every day!</p>\n")
        write(self.root, f"{MARKETING}/content/meet-daily-reward.ts", "export const t = 'Spin to earn cash';\n")
        write(self.root, f"{MARKETING}/app/[locale]/legal/child-safety/page.tsx", "<p>No sugar daddies</p>\n")
        write(self.root, f"{MARKETING}/components/MeetupBanner.tsx", "<p>Generous hosts</p>\n")
        write(self.root, f"{MARKETING}/app/[locale]/page.tsx", "<p>Pay cash on delivery</p>\n")
        write(self.root, f"{MARKETING}/app/[locale]/how-it-works/meeting-point.tsx",
              "<p>Pay cash at the meeting point</p>\n")
        self.assertEqual(sorted(self.messages()), sorted(
            f"{MARKETING}/{path}: Meet copy: line 1 says {term!r}, which docs/store/meet-copy-rules.md forbids"
            for path, term in [
                ("app/[locale]/meet/page.tsx", "Earn"),
                ("app/[locale]/legal/meet-guidelines/page.tsx", "Earn"),
                ("content/meet-daily-reward.ts", "earn"),
                ("content/meet-daily-reward.ts", "cash"),
                ("app/[locale]/legal/child-safety/page.tsx", "sugar"),
                ("components/MeetupBanner.tsx", "Generous"),
            ]
        ))

    def test_an_exempt_phrase_passes_and_nothing_else_on_its_line_does(self):
        terms = f"{MARKETING}/content/meet-terms.ts"
        write(self.root, terms,
              "export const t = {\n"
              "  value: 'Cowries have no cash value and can’t be withdrawn.',\n"
              "  promo: 'Cowries have no cash value, so earn more!',\n"
              "  title: 'No cash value',\n"
              "};\n")
        write(self.root, f"{MARKETING}/content/meet-guidelines.ts", "export const g = 'Cowries have no cash value';\n")
        with self.exempting({f"{terms}#no cash value": "the no-cash-value disclosure (design §8.12)",
                             f"{terms}#can’t be withdrawn": "the no-withdrawal disclosure"}):
            messages = self.messages()
        self.assertEqual(sorted(messages), sorted([
            f"{terms}: Meet copy: line 3 says 'earn', which docs/store/meet-copy-rules.md forbids",
            f"{terms}: Meet copy: line 4 says 'cash', which docs/store/meet-copy-rules.md forbids",
            f"{MARKETING}/content/meet-guidelines.ts: Meet copy: line 1 says 'cash', which "
            "docs/store/meet-copy-rules.md forbids",
        ]))

    def test_an_exemption_names_one_key(self):
        self.arb(ARB_EN, {"meetCowriesNoCashValue": "Cowries have no cash value", "meetB": "Cash only"})
        with self.exempting({f"{ARB_EN}#meetCowriesNoCashValue": "the store's no-cash-value disclosure"}):
            self.assertEqual(self.flagged(), ["meetB"])

    def test_an_exemption_needs_a_target_and_a_reason_and_must_still_exempt_something(self):
        write(self.root, f"{MARKETING}/content/meet-terms.ts", "export const t = 'Free to join';\n")
        with self.exempting({
            f"{MARKETING}/app/[locale]/legal/": "a whole folder",
            f"{ARB_EN}#meetTitle": " ",
            f"{MARKETING}/content/meet-terms.ts#no cash value": "the disclosure, since reworded",
            f"{ARB_EN}#meetGone": "a key that was removed",
        }):
            findings = [(f.level, f.message) for f in check_preview.check(self.root)]
        needs = "needs the form `<path>#<key or phrase>` and a reason"
        stale = "no longer exempts anything; remove it"
        self.assertEqual(findings, [
            ("error", f"Meet copy exemption '{MARKETING}/app/[locale]/legal/' {needs}"),
            ("error", f"Meet copy exemption '{ARB_EN}#meetTitle' {needs}"),
            ("warning", f"Meet copy exemption '{MARKETING}/content/meet-terms.ts#no cash value' {stale}"),
            ("warning", f"Meet copy exemption '{ARB_EN}#meetGone' {stale}"),
        ])


if __name__ == "__main__":
    unittest.main()
